---
title: Security model
description: What TestFleet protects, how, and where its limits are.
---

TestFleet runs code from container images against your systems, with credentials you give it. It is designed for a **trusted internal network**: it protects secrets and isolates test containers from TestFleet itself, but it is not a sandbox between mutually distrusting tenants.

## Secrets

- **Encrypted at rest:** environment variable values (all of them, not only secrets), registry passwords, and notification webhook URLs and signing secrets, with AES-256-GCM under `CLOAK_KEY`.
- **Never sent back:** after saving, secret values, registry passwords, and webhook URLs are never sent to the browser. Forms leave them empty ("leave empty to keep the current value").
- **Masked in logs:** every occurrence of a secret value of the run's environment is replaced with `[MASKED]` before a log line is stored or streamed. Secrets need at least 6 characters, because shorter values cannot be masked reliably.
- **Not in notifications:** messages contain test names, never failure messages, log lines, or variables.
- **Not in TestFleet's own logs:** URLs of notification channels, `Authorization` headers, and secret values are kept out of logs and crash reports.

**Known limit:** anyone with Docker access on the host can read a running container's environment with `docker inspect`, secrets included.

## Test containers

Every run's container is created with:

- all Linux capabilities dropped, and `no-new-privileges`
- no privileged mode, no host mounts, no access to the Docker socket
- CPU and memory limits from the test definition, and a mandatory timeout
- the network `TestFleet-runs`, separate from TestFleet's own: a suite can reach the systems it tests, but not TestFleet's database or the socket proxy

A suite still has outbound network access, and the credentials of its environment. Treat suite images like any other code you deploy: build them in your pipelines, from your repositories.

## Docker access

Access to the Docker socket is equivalent to root on the host. Only the socket proxy mounts it, read-only, and it allows only the endpoints TestFleet uses: containers, images, networks, and registry authentication. TestFleet reaches it over an internal network without a route out.

TestFleet passes registry credentials per pull. It never runs `docker login` and never writes credentials to the host.

## The application

- **Every page requires a login.** There is no open registration; the first admin needs a one-time link from the server's log.
- **Roles:** admins manage users, registries, and notification channels; members everything around testing. See [Users and access](/guides/users/).
- **API tokens** are stored as SHA-256 hashes, shown once, can expire, and die with their user's deactivation. They start with `tf_`, so secret scanners can recognize them; GitHub push protection accepts custom patterns such as `tf_[A-Za-z0-9_-]{43}`.
- **Artifacts are untrusted.** HTML reports and SVGs from suites are served with a sandboxing Content Security Policy, so their scripts run in an isolated origin without access to TestFleet's session. Archive entries that are links or escape the artifacts directory are skipped. JUnit files are parsed without external entities.
- **The TestFleet container** runs as `nobody`, read-only, with all capabilities dropped.

## Recommendations

- Put TestFleet behind TLS on an internal network; do not expose it to the internet.
- Use single sign-on, and `OIDC_ALLOWED_DOMAINS` or provider-side assignment to limit who gets in.
- Use dedicated, read-only registry credentials, and dedicated test users in the systems under test, with the least privileges the suites need.
- Keep production environments' concurrency limit at 1 unless you have a reason.
- Back up `CLOAK_KEY` separately from the database backups.
