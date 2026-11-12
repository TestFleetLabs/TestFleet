# Changelog

All notable changes to TestFleet. The image for each version is `ghcr.io/testfleetlabs/testfleet:<version>`.

Each version lists its changes in this order, leaving out empty sections:

- **Upgrade notes:** what you must do when upgrading, such as a changed setting or a breaking change
- **Enhancements:** new features and improvements
- **Bug fixes**

## Unreleased

## 0.4.2 (2026-11-12)

### Upgrade notes

- `deploy/compose.yaml` pins the Docker socket proxy to `v0.5.0` instead of `latest`; copy the file again, or change the tag in yours
- Test containers are limited to 4,096 processes and threads

### Enhancements

- Password logins are limited to 10 attempts per email address in 10 minutes, and login links to 5 per address in 15 minutes
- TestFleet's pages send a Content Security Policy
- `WEBHOOK_ALLOW_PRIVATE_HOSTS=false` refuses webhook URLs whose host is on an internal network
- Docker's own copy of a container's output is capped, so it cannot fill the host's disk

### Bug fixes

- A run whose artifacts could not be collected (a full disk, a broken archive) no longer stays `running` forever: it ends with its status and a warning
- A JUnit file in UTF-16 can no longer get a `DOCTYPE` past the check
- A schedule that fails no longer keeps the schedules after it from running
- Downloading a log no longer holds a database connection for as long as the download takes
- A short PostgreSQL outage no longer stops TestFleet
- An error while preparing a run is reported as it is, not as "lost the run while preparing it"
- Pulling an image whose layers take minutes to extract no longer fails after 60 seconds of silence

## 0.4.1 (2026-11-08)

### Enhancements

- Admins see when a newer TestFleet release is out: an orange dot on the settings icon and, on their settings page, an alert with the installed and the new version and a link to the release. TestFleet asks GitHub for the latest release twice a day and never downloads or installs anything. `UPDATE_CHECK=false` turns the check off

## 0.4.0 (2026-11-07)

### Upgrade notes

- To record what a pipeline deployed, copy the CI scripts again (`deploy/ci/testfleet-run.sh`, `deploy/ci/testfleet-run.ps1`). Older copies keep working; they just do not send it

### Enhancements

- Every test has its own page: its latest outcome, streak, pass rate, and flips per environment, a strip of its last 30 outcomes, and its history. Test names on the run page link to it
- Flaky tests (3 or more flips between passed and failed on the same image in the last 30 runs) are listed on the test definition page and marked on the run page. Flakiness is only shown; it never changes a run's status
- Failed tests on the run page say whether they are new, failing since an earlier run, or seen for the first time
- The run page's Changes panel compares the run with the previous run, the last passed run, or any run: new failures, fixed, still failing, added, and removed tests, and whether the image, deployment, command, or duration changed
- API runs can record what was deployed (`"deployment": {"version", "commit", "url"}`). The run page, the runs list, the API, and notifications show it. The CI scripts send the tag as the version and find the commit and the pipeline link in GitHub Actions, GitLab CI, Azure Pipelines, and Jenkins
- The runs list filters by project, environment, status, trigger, days, and deployment (version or commit), pages through all runs, and keeps both in the URL, so a filtered list can be shared

## 0.3.2 (2026-11-07)

### Enhancements

- The image is built with Elixir 1.20.5 and Erlang/OTP 29.1.2 on a newer Debian trixie base
- Update dependencies, among them Bandit 1.14.1 and Phoenix HTML 4.4.0

## 0.3.1 (2026-10-20)

### Enhancements

- Finished background jobs are deleted after 2 days instead of 7, which keeps the jobs table small. Run history and notification deliveries are not affected
- Update dependencies, among them Phoenix 1.8.16 and Phoenix LiveView 1.2.13

## 0.3.0 (2026-10-18)

### Enhancements

- A test definition can keep its runs' artifacts and logs for its own number of days, shorter or longer than the instance defaults (`ARTIFACT_RETENTION_DAYS`, `LOG_RETENTION_DAYS`)
- Admins have a Statistics page: runs, configuration, and stored artifacts and logs, the suites holding the most artifacts, and, with a single organization, the free space of the artifacts disk, the database's largest tables, and the Docker images TestFleet pulled

### Bug fixes

- The icons of the "New token" and "Invite" buttons disappeared after a click

## 0.2.4 (2026-10-17)

### Enhancements

- Update dependencies, among them the web server (Bandit 1.13)

## 0.2.3 (2026-10-14)

### Enhancements

- Download all of a run's artifacts as one ZIP archive from the artifacts panel

## 0.2.2 (2026-10-11)

### Enhancements

- Each release on GitHub now has release notes taken from this changelog and the command to pull its image

### Bug fixes

- Generating the SBOM for a release failed

## 0.2.1 (2026-10-11)

### Enhancements

- Admins can delete a finished run from its page, together with its log, test results, artifacts, and notification history
- A CycloneDX SBOM of the production dependencies is attached to each release
- Update dependencies

## 0.2.0 (2026-10-07)

The first release.

### Enhancements

- Projects, environments with encrypted variables, test definitions, and private registries
- Runs started manually, by timezone-aware cron schedules, or through the API, all through one queue with global and per-environment concurrency limits
- Live run output with secrets masked, stored up to a per-run limit and downloadable
- JUnit test results and artifacts on the run page, including HTML reports, screenshots, and videos
- Retention for artifacts and logs, with pinned runs and the latest failure kept
- Recovery after a TestFleet restart or a Docker outage: running suites are reattached without losing output
- Cleanup of unused images and orphaned artifact files
- Notifications by email, Slack, Microsoft Teams, and webhooks when a series starts failing or recovers, and when TestFleet itself has a problem, plus a heartbeat URL
- Login with password or single sign-on (OIDC), invitations, and admin and member roles
- Organizations, with all data scoped to the user's organization
- API tokens and a REST API for runs, logs, artifacts, and updating a test definition's image from CI
- A container image for linux/amd64 and linux/arm64 on GHCR, with a production Compose file
