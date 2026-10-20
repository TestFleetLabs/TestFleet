# Changelog

All notable changes to TestFleet. The image for each version is `ghcr.io/testfleetlabs/testfleet:<version>`.

Each version lists its changes in this order, leaving out empty sections:

- **Upgrade notes:** what you must do when upgrading, such as a changed setting or a breaking change
- **Enhancements:** new features and improvements
- **Bug fixes**

## Unreleased

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
