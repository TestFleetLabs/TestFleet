---
title: Configuration
description: Every environment variable TestFleet reads, with its default.
---

TestFleet is configured through environment variables in `.env`, next to `compose.yaml`. Restart after a change: `docker compose up -d`.

## Required

| Variable            | Notes                                                                                                                                                                                              |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PHX_HOST`          | The public host name, as the reverse proxy serves it over HTTPS. Used for links in notifications, invitations, and API responses.                                                                  |
| `SECRET_KEY_BASE`   | Signs and encrypts sessions. `openssl rand -base64 48`                                                                                                                                             |
| `CLOAK_KEY`         | Encrypts environment variables, registry passwords, and notification URLs at rest. 32 bytes, base64: `openssl rand -base64 32`. **Back it up**; it cannot be changed without losing those secrets. |
| `POSTGRES_PASSWORD` | The database password. `openssl rand -hex 24` (URL-safe, because it becomes part of the database URL)                                                                                              |

## Deployment

| Variable            | Default                                  |                                  |
| ------------------- | ---------------------------------------- | -------------------------------- |
| `TESTFLEET_IMAGE`   | `ghcr.io/testfleetlabs/testfleet:latest` | The image to run. Pin a release. |
| `TESTFLEET_PUBLISH` | `127.0.0.1:4000`                         | Where the port is published      |
| `POOL_SIZE`         | `10`                                     | Database connections             |

## Execution

| Variable               | Default |                                                                                                                 |
| ---------------------- | ------- | --------------------------------------------------------------------------------------------------------------- |
| `MAX_CONCURRENT_RUNS`  | `10`    | Runs preparing or running at the same time, across all environments. Each environment has its own limit on top. |
| `PULL_TIMEOUT_SECONDS` | `600`   | How long an image pull may take; separate from the run's timeout                                                |
| `RUN_LOG_LIMIT_MB`     | `50`    | Stored log per run; later output is shown live but not stored                                                   |
| `ARTIFACT_LIMIT_MB`    | `500`   | Artifacts per run; over it, only the JUnit files are kept                                                       |

## Retention

| Variable                  | Default |                                                           |
| ------------------------- | ------- | --------------------------------------------------------- |
| `ARTIFACT_RETENTION_DAYS` | `30`    | Days after a run finished until its artifacts are removed |
| `LOG_RETENTION_DAYS`      | `90`    | The same for its log                                      |
| `IMAGE_RETENTION_DAYS`    | `7`     | Days an unused suite image stays on the host              |

Pinned runs, and the latest failed, timed-out, or errored run of each test definition and environment, keep their artifacts and log regardless. Runs and test results are never removed. See [Retention](/suites/results-and-artifacts/#retention).

Image cleanup removes only images that TestFleet's own runs pulled, by digest, and never the image an enabled test definition currently uses.

## Email (SMTP)

Without `SMTP_HOST`, TestFleet sends no email: invitation links are only shown to copy, the email login link is unavailable, and email notification channels report "Email is not configured on this server".

| Variable                         | Default                |                                                             |
| -------------------------------- | ---------------------- | ----------------------------------------------------------- |
| `SMTP_HOST`                      | –                      | The mail server                                             |
| `SMTP_PORT`                      | `587`                  |                                                             |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | –                      | Without a user name, TestFleet sends without authentication |
| `SMTP_TLS`                       | `if_available`         | `always`, `if_available`, or `never`                        |
| `SMTP_FROM`                      | `testfleet@<PHX_HOST>` | The sender address                                          |

## Single sign-on

| Variable                               | Default                |                                                                                   |
| -------------------------------------- | ---------------------- | --------------------------------------------------------------------------------- |
| `OIDC_ISSUER`                          | –                      | Enables OpenID Connect login                                                      |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | –                      | Required with `OIDC_ISSUER`                                                       |
| `OIDC_PROVIDER_NAME`                   | `single sign-on`       | The button reads "Log in with …"                                                  |
| `OIDC_SCOPES`                          | `openid email profile` |                                                                                   |
| `OIDC_EMAIL_CLAIM`                     | `email`                | The claim with the user's email address; often `preferred_username` with Entra ID |
| `OIDC_USER_PROVISIONING`               | `true`                 | `false`: only invited users can log in with the provider                          |
| `OIDC_ALLOWED_DOMAINS`                 | –                      | Comma-separated; only these email domains get an account on first login           |
| `AUTH_PASSWORD_LOGIN`                  | `true`                 | `false`: single sign-on only. Refused at startup without `OIDC_ISSUER`.           |

See [Single sign-on](/operate/single-sign-on/).

## Monitoring

| Variable        | Default |                                                                                                        |
| --------------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `HEARTBEAT_URL` | –       | Pinged with `GET` after every schedule tick, for an external dead man's switch such as Healthchecks.io |

`GET /health` answers `200` while TestFleet is up; the Compose file uses it as the container's health check.

## Set by the Compose file

These are wired up in `compose.yaml` and rarely need changing: `DATABASE_URL` (from `POSTGRES_PASSWORD`), `DOCKER_HOST` (`tcp://docker-socket-proxy:2375`), and `ARTIFACTS_DIR` (`/app/artifacts`).
