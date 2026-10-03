---
title: Upgrade, back up, maintain
description: Upgrade TestFleet, back it up, and the commands for day-to-day operation.
---

## Upgrade

Set the new version in `.env`, then pull and restart:

```ini title=".env"
TESTFLEET_IMAGE=ghcr.io/testfleetlabs/testfleet:1.3.0
```

```sh
docker compose pull
docker compose up -d
```

Migrations run on start. **Running tests survive the upgrade:** their containers keep running while TestFleet restarts, and TestFleet reattaches to them when it is back, with their log continuing where it left off. Time spent down counts against their timeout. Queued runs wait and start once TestFleet is up.

### Image tags

| Tag                    | Published for                                              |
| ---------------------- | ---------------------------------------------------------- |
| `1.2.3`, `1.2`         | The release `v1.2.3`                                       |
| `latest`               | The newest release (not prereleases such as `v1.3.0-rc.1`) |
| `main`, `sha-<commit>` | Every commit on `main` that passed CI                      |

Every tag holds images for `linux/amd64` and `linux/arm64`.

## Back up

| What                              | How                                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------ |
| **`.env`, above all `CLOAK_KEY`** | Keep it in your secret store. Without the key, a restored database has unreadable secrets. |
| The database                      | `docker compose exec db pg_dump -U testfleet testfleet > testfleet.sql`                    |
| Artifacts                         | The `testfleet_artifacts` volume, or your host directory (below)                           |

The TestFleet container holds nothing; it can be removed and recreated at any time.

To restore, start only the database, load the dump, then start the rest:

```sh
docker compose up -d db
docker compose exec -T db psql -U testfleet testfleet < testfleet.sql
docker compose up -d
```

## Day to day

| Task                   | Command                                                                                                                                      |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Logs                   | `docker compose logs -f testfleet`                                                                                                           |
| Health                 | `curl http://127.0.0.1:4000/health`                                                                                                          |
| Remote shell           | `docker compose exec testfleet bin/testfleet remote`                                                                                         |
| Run migrations by hand | `docker compose exec testfleet bin/migrate`                                                                                                  |
| Lost admin access      | `docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'` prints a link that sets a new password |
| Roll back migrations   | `docker compose exec testfleet bin/testfleet eval 'TestFleet.Release.rollback(TestFleet.Repo, 20260930000000)'`                              |

### What TestFleet cleans up by itself

- **Containers:** each run's container is removed after its results are collected. A reconciler also removes containers left behind by a crash, after finalizing their runs.
- **Artifacts and logs:** expired hourly, see [Retention](/suites/results-and-artifacts/#retention).
- **Images:** suite images no run has used for 7 days are removed by digest (`IMAGE_RETENTION_DAYS`). The current image of every enabled test definition is kept.
- **Notification deliveries:** after 90 days.

TestFleet only touches containers and images it created itself. It never prunes Docker.

## Artifacts on a host directory

Artifacts are kept in a named volume. To keep them in a host directory instead, for example on a larger disk, give it to UID 65534 (`nobody`, which TestFleet runs as) and mount it at `/app/artifacts`:

```sh
sudo mkdir -p /var/lib/testfleet/artifacts
sudo chown 65534 /var/lib/testfleet/artifacts
```

```yaml title="compose.override.yaml"
services:
  testfleet:
    volumes:
      - /var/lib/testfleet/artifacts:/app/artifacts
```

## Trying a build on a development machine

Build the image from the repository root:

```sh
docker build -t testfleet:dev .
```

The development `compose.yaml` in the repository root uses the same Compose project name (`testfleet`). Give the production stack another one, and another port, so the two do not take over each other's containers:

```sh
cd deploy
TESTFLEET_IMAGE=testfleet:dev TESTFLEET_PUBLISH=127.0.0.1:4100 docker compose -p testfleet-local up -d
```

TestFleet always pulls suite images that are referenced by tag, so a suite image has to come from a registry, not only from the local image store.
