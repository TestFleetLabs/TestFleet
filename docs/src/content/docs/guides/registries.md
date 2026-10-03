---
title: Registries
description: Give TestFleet credentials for private container registries.
---

TestFleet pulls each suite's image itself, before every run of a tag. Public images need no setup. For private ones, an **admin** adds the registry's credentials once under **Registries**; every test definition whose image is on that host uses them.

## Adding a registry

| Field        | Example          | Notes                                                                                                                                 |
| ------------ | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Name**     | GitHub packages  | For people                                                                                                                            |
| **Host**     | `ghcr.io`        | Matched against the host of image references. No scheme, no path. Include a port if the registry has one: `registry.example.com:5000` |
| **Username** | `testfleet-pull` |                                                                                                                                       |
| **Password** | a token          | Encrypted at rest, never shown again                                                                                                  |

**Test connection** checks the credentials against the registry without pulling anything, before or after saving. Docker's error message is shown as-is.

An image is matched by its host: `ghcr.io/acme/portal-e2e:1.4.2` uses the `ghcr.io` registry. An image without a host, such as `node:22` or `acme/e2e:1.0`, is on Docker Hub and matches a registry with the host `docker.io`. Images whose host has no registry are pulled anonymously; the test definition form shows which applies.

TestFleet passes the credentials with each pull. It never runs `docker login` and never writes a Docker config file on the host.

## Credentials for common registries

Use a dedicated, read-only credential for TestFleet, not a person's account.

| Registry                  | Host                                     | Username                            | Password                                                                                                     |
| ------------------------- | ---------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| GitHub Container Registry | `ghcr.io`                                | any user name                       | A personal access token (classic) with `read:packages`, or a fine-grained token with read access to packages |
| GitLab Container Registry | `registry.gitlab.com` or your instance's | the deploy token's user name        | A deploy token with `read_registry`                                                                          |
| Docker Hub                | `docker.io`                              | the account                         | A personal access token with read-only scope                                                                 |
| Azure Container Registry  | `<name>.azurecr.io`                      | the token or service principal name | A repository-scoped token with `content/read`, or a service principal's secret                               |
| Harbor                    | your Harbor host                         | `robot$…`                           | A robot account with pull permission                                                                         |
| Any other OCI registry    | its host                                 | a user with pull access             | its password or token                                                                                        |

Amazon ECR is not supported yet: its passwords expire after 12 hours and have to be fetched from AWS before each pull.

## Changing and removing

Leave the password empty when editing to keep the current one. A changed credential applies to the next pull. Deleting a registry makes its images pull anonymously, which fails for private images.
