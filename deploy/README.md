# Deploying TestFleet

TestFleet runs as three containers on one Docker host: TestFleet itself, PostgreSQL, and a Docker socket proxy. TestFleet starts the test containers on the host's Docker Engine through the proxy. Design and reasoning: [.specs/milestone-9-deployment.md](../.specs/milestone-9-deployment.md).

## Requirements

- Docker Engine with Compose v2.20 or later
- A reverse proxy (nginx, Traefik, Caddy) that terminates TLS, sets `X-Forwarded-Proto`, and passes WebSocket upgrades on `/live`

## Install

The server needs only this directory's `compose.yaml` and `.env.example`; the image comes from `ghcr.io/testfleetlabs/testfleet`.

```sh
mkdir testfleet && cd testfleet
# copy compose.yaml and .env.example here
cp .env.example .env
```

Fill in the four required values in `.env`, and pin `TESTFLEET_IMAGE` to a release:

```sh
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -base64 32   # CLOAK_KEY
openssl rand -hex 24      # POSTGRES_PASSWORD
```

Start it:

```sh
docker compose up -d
docker compose ps          # all three healthy
```

Migrations run on every start. TestFleet listens on `127.0.0.1:4000` (`TESTFLEET_PUBLISH`); point the reverse proxy at it:

```nginx
location / {
  proxy_pass http://127.0.0.1:4000;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto https;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
}
```

TestFleet redirects plain HTTP requests to HTTPS, except on `localhost`.

### First login

Every page needs a login. While there is no user, TestFleet logs a one-time link on each start:

```sh
docker compose logs testfleet | grep "No users yet"
# No users yet. Create the first admin at https://testfleet.example.internal/setup?token=…
```

Open it to create the first admin; `/setup` without the token does not exist. Everyone else is invited from the Users page: the invitation link is shown to copy, and emailed too when SMTP is configured.

## Single sign-on

TestFleet logs in with one OpenID Connect provider. It is found through the provider's discovery document, so anything that speaks OIDC works. Set the `OIDC_*` variables in `.env` (see `.env.example`) and register `https://<PHX_HOST>/auth/oidc/callback` as the redirect URI at the provider.

**Which issuer?** If another internal application already logs in with the company provider (for example Dependency-Track, with its `ALPINE_OIDC_ISSUER`), its issuer tells you which provider you have:

- `https://login.microsoftonline.com/<tenant-id>/v2.0`: **Entra ID**. Create an app registration: a web platform with the redirect URI above, and a client secret (`OIDC_CLIENT_SECRET`); the application (client) ID is `OIDC_CLIENT_ID`. To let only certain people in, set "Assignment required" on its enterprise application and assign them.
- `https://<adfs-host>/adfs`: **AD FS** (on-premises Active Directory). Create an application group with a server application: the redirect URI above, a client secret, and issuance rules that add the email address.

**Email claim.** TestFleet names users by email. Entra sends `email` only for users with a mailbox or when it is added as an optional claim; otherwise set `OIDC_EMAIL_CLAIM=preferred_username` (the UPN). Users are matched by the provider's subject, not by email, so changing the email later does not create a second account.

**Who gets in.** With `OIDC_USER_PROVISIONING=true` (the default), anyone the provider lets through gets a member account on first login, optionally limited by `OIDC_ALLOWED_DOMAINS`; admins promote them on the Users page. With `false`, only invited users get in. Neither Entra nor AD FS confirms that an email address is verified, so an existing TestFleet account is never taken over by email: invitation links offer "Continue with <provider>", which links the account at the provider.

**SSO button only.** `AUTH_PASSWORD_LOGIN=false` removes password login, like Dependency-Track behind the same provider. The first-run setup link then creates the first admin through the provider too.

## Upgrade

Set the new version in `TESTFLEET_IMAGE`, then:

```sh
docker compose pull
docker compose up -d
```

Migrations run on start. Running tests survive the restart: their containers keep running, and TestFleet picks them up again when it is back. Time spent down counts against their timeout.

## Operate

| Task | Command |
|------|---------|
| Logs | `docker compose logs -f testfleet` |
| Health | `curl http://127.0.0.1:4000/health` |
| Remote shell | `docker compose exec testfleet bin/testfleet remote` |
| Run migrations by hand | `docker compose exec testfleet bin/migrate` |
| Lost admin access | `docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'` prints a link that sets a new password |
| Roll back migrations | `docker compose exec testfleet bin/testfleet eval 'TestFleet.Release.rollback(TestFleet.Repo, 20260930000000)'` |

## Back up

- **`.env`, above all `CLOAK_KEY`.** It encrypts environment variables, registry passwords, and notification URLs; a database restored without it has unreadable secrets.
- The database: `docker compose exec db pg_dump -U testfleet testfleet > testfleet.sql`
- The `testfleet_artifacts` volume (screenshots, videos, reports)

The TestFleet container itself holds nothing; it can be removed and recreated at any time.

## Artifacts on a host directory

Artifacts are kept in a named volume. To keep them in a host directory instead, give it to UID 65534 and mount it at `/app/artifacts`:

```sh
sudo mkdir -p /var/lib/testfleet/artifacts
sudo chown 65534 /var/lib/testfleet/artifacts
```

```yaml
# compose.override.yaml
services:
  testfleet:
    volumes:
      - /var/lib/testfleet/artifacts:/app/artifacts
```

## Images

| Tag | Published for |
|-----|---------------|
| `1.2.3`, `1.2` | the git tag `v1.2.3` |
| `latest` | the newest release (not prereleases like `v1.3.0-rc.1`) |
| `main`, `sha-<commit>` | every commit on `main`, once CI is green |

Only `linux/amd64` is published for now.

## Trying it on a development machine

Build the image from the repository root:

```sh
docker build -t testfleet:dev .
```

The development `compose.yaml` in the repository root has the same Compose project name (`testfleet`). Give the production stack another one, and another port, so the two do not take over each other's containers:

```sh
cd deploy
TESTFLEET_IMAGE=testfleet:dev TESTFLEET_PUBLISH=127.0.0.1:4100 docker compose -p testfleet-local up -d
```

TestFleet always pulls images, so a suite image has to come from a registry, not only from the local image store.

## Security

The socket proxy only lets TestFleet reach the container, image, network, and registry auth endpoints, and only the proxy mounts the Docker socket. Docker API access is still highly privileged: this setup is for a trusted internal network, not an isolation boundary between tenants.
