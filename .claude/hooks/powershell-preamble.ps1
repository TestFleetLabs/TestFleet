<#
.SYNOPSIS
  PreToolUse hook: prepends a fixed preamble to every PowerShell tool command.

.DESCRIPTION
  Reads the hook payload on stdin and returns it with `tool_input.command`
  rewritten, which is the only way to influence the tool's shell — a hook runs in
  its own process and cannot reach into the tool's environment.

  Two problems, neither of which has a settings key:

  1. The tool's working directory persists between calls, so one stray
     `Set-Location backend` silently relocates every later command. Pinning the
     root each time makes each command independent of the one before it.

  2. The tool starts pwsh without a profile, so the fnm and mise activation lines
     in Microsoft.PowerShell_profile.ps1 never run. Activating mise here would not
     help anyway: `C:\Program Files\nodejs` is in the MACHINE PATH, which Windows
     always orders ahead of the user PATH where mise puts its own entries, so the
     system Node 20 shadows the pinned one either way. Prepending mise's node
     install directory is what actually wins.

  Elixir needs nothing — no other `mix` is on the machine, so the mise shim on the
  user PATH already resolves the version pinned in .tool-versions.

  Degrades quietly: with no mise on PATH the command is still pinned to the root
  and simply runs against whatever node is there.
#>

$ErrorActionPreference = 'Stop'

$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json

# Derived from where this file sits (<root>/.claude/hooks), not from the payload:
# `cwd` is whatever the previous command left behind, which is the thing being
# corrected here. CLAUDE_PROJECT_DIR overrides it if Claude Code exports one.
$root = if ($env:CLAUDE_PROJECT_DIR) {
  $env:CLAUDE_PROJECT_DIR
} else {
  Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# Resolved here rather than in the emitted command so a missing mise costs one
# failed lookup in the hook instead of breaking every command in the session.
# Re-resolved per command, so bumping node in .tool-versions needs no edit here.
$nodeDir = $null
if (Get-Command mise -ErrorAction SilentlyContinue) {
  try {
    # Validated by Test-Path rather than by $LASTEXITCODE: `Select-Object -First 1`
    # short-circuits the pipeline, so the native exit code is never recorded and
    # reads back as empty even on success.
    $candidate = (& mise where node 2>$null | Select-Object -First 1)
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      $nodeDir = $candidate
    }
  } catch {
    # No node pinned for this project, or mise cannot resolve it. Not an error:
    # the backend-only commands in this repo do not need node at all.
  }
}

$parts = @()
if ($root) { $parts += ("Set-Location -LiteralPath '" + $root.Replace("'", "''") + "'") }
if ($nodeDir) { $parts += ('$env:PATH = ''' + $nodeDir + ';'' + $env:PATH') }

if ($parts.Count -gt 0) {
  $payload.tool_input.command = ($parts -join '; ') + '; ' + $payload.tool_input.command
}

@{
  hookSpecificOutput = @{
    hookEventName = 'PreToolUse'
    updatedInput  = $payload.tool_input
  }
} | ConvertTo-Json -Depth 20 -Compress
