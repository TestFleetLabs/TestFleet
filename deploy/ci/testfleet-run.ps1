# Starts a TestFleet run and waits for it, printing its log as it goes.
#
#   testfleet-run.ps1 <project> <test-definition> <environment> [tag]
#
# With a tag, the test definition's image tag is updated first, so this run and
# every scheduled run after it use the matching E2E image.
#
# Environment: TESTFLEET_URL (https://testfleet.example.internal), TESTFLEET_TOKEN
# (an API token from Settings), TESTFLEET_POLL_SECONDS (default 5).
# Needs PowerShell 7.
#
# Exit status: 0 when the run passed, 1 when its tests failed, 2 for everything
# else (error, timeout, cancelled, or a refused request).
param(
  [Parameter(Mandatory)] [string] $Project,
  [Parameter(Mandatory)] [string] $TestDefinition,
  [Parameter(Mandatory)] [string] $Environment,
  [string] $Tag
)

$ErrorActionPreference = 'Stop'

if (-not $env:TESTFLEET_URL) { Write-Error 'set TESTFLEET_URL' }
if (-not $env:TESTFLEET_TOKEN) { Write-Error 'set TESTFLEET_TOKEN' }

$base = "$($env:TESTFLEET_URL.TrimEnd('/'))/api/v1"
$headers = @{ Authorization = "Bearer $env:TESTFLEET_TOKEN" }
$poll = if ($env:TESTFLEET_POLL_SECONDS) { [int]$env:TESTFLEET_POLL_SECONDS } else { 5 }

# Calls the API; stops with TestFleet's message on an error response.
function Invoke-TestFleet([string] $Method, [string] $Path, $Body) {
  $request = @{ Method = $Method; Uri = "$base$Path"; Headers = $headers }
  if ($null -ne $Body) {
    $request.ContentType = 'application/json'
    $request.Body = $Body | ConvertTo-Json
  }

  try {
    Invoke-RestMethod @request
  } catch {
    $status = $_.Exception.Response.StatusCode.value__
    $error_body = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $null }
    $message = if ($error_body) { $error_body.message } else { $_.Exception.Message }
    [Console]::Error.WriteLine("TestFleet answered ${status}: $message")
    if ($error_body.details) {
      foreach ($field in $error_body.details.PSObject.Properties) {
        [Console]::Error.WriteLine("  $($field.Name) $($field.Value -join ', ')")
      }
    }
    exit 2
  }
}

if ($Tag) {
  $definition = Invoke-TestFleet PATCH "/projects/$Project/test-definitions/$TestDefinition" @{ tag = $Tag }
  Write-Host "TestFleet: $TestDefinition now uses $($definition.image)"
}

$run = Invoke-TestFleet POST "/projects/$Project/runs" @{ test_definition = $TestDefinition; environment = $Environment }
Write-Host "TestFleet: run $($run.id) of $($run.image) on $Environment"
Write-Host "TestFleet: $($run.url)"

# Prints the log lines stored since the last call.
$script:sequence = 0
function Write-NewLog {
  $response = Invoke-WebRequest -Uri "$base/runs/$($run.id)/log?after=$script:sequence" -Headers $headers -SkipHttpErrorCheck
  if ($response.StatusCode -eq 200) {
    [Console]::Out.Write($response.Content)
    $next = $response.Headers['testfleet-log-sequence']
    if ($next) { $script:sequence = [int]($next | Select-Object -First 1) }
  }
}

while ($true) {
  Write-NewLog
  $run = Invoke-TestFleet GET "/runs/$($run.id)"
  if ($run.final) { break }
  Start-Sleep -Seconds $poll
}

# Lines stored between the last log request and the end of the run
Write-NewLog

$detail =
  if ($run.tests) { " ($($run.tests.passed) passed, $($run.tests.failed) failed, $($run.tests.skipped) skipped)" }
  elseif ($run.error_message) { ": $($run.error_message)" }
  else { '' }
Write-Host "TestFleet: run $($run.id) $($run.status)$detail"

switch ($run.status) {
  'passed' { exit 0 }
  'failed' { exit 1 }
  default { exit 2 }
}
