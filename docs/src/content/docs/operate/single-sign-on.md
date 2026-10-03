---
title: Single sign-on
description: Log in to TestFleet with Entra ID, AD FS, Keycloak, or any OpenID Connect provider.
---

TestFleet logs in with one OpenID Connect provider. It finds the provider through its discovery document, so anything that speaks OIDC works: Microsoft Entra ID, AD FS, Keycloak, Authentik, Okta, Google, GitLab, and others.

## Configure

1. Register TestFleet at the provider as a **confidential client** (a web application with a client secret), with the redirect URI:

   ```text
   https://<PHX_HOST>/auth/oidc/callback
   ```

2. Set the variables in `.env`:

   ```ini title=".env"
   OIDC_ISSUER=https://login.microsoftonline.com/<tenant-id>/v2.0
   OIDC_CLIENT_ID=…
   OIDC_CLIENT_SECRET=…
   OIDC_PROVIDER_NAME=Microsoft
   ```

3. `docker compose up -d`. The login page now offers **Log in with Microsoft**.

If the provider cannot be reached when TestFleet starts, TestFleet starts anyway and keeps retrying; until then, the button says single sign-on is not available right now.

## Which issuer?

If another internal application already logs in with your company's provider (for example Dependency-Track, with its `ALPINE_OIDC_ISSUER`), its issuer tells you which provider you have.

### Entra ID

Issuer: `https://login.microsoftonline.com/<tenant-id>/v2.0`

Create an **app registration**: a web platform with the redirect URI above, and a client secret (`OIDC_CLIENT_SECRET`). The application (client) ID is `OIDC_CLIENT_ID`.

To let only certain people in, set **Assignment required** on its enterprise application and assign them or their groups.

Entra sends the `email` claim only for users with a mailbox, or when it is added as an optional claim. Otherwise set:

```ini
OIDC_EMAIL_CLAIM=preferred_username
```

### AD FS

Issuer: `https://<adfs-host>/adfs`

Create an **application group** with a server application: the redirect URI above, a client secret, and issuance transform rules that add the email address.

### Keycloak

Issuer: `https://<keycloak-host>/realms/<realm>`

Create an OpenID Connect client with **Client authentication** on, the redirect URI above as a valid redirect URI, and use the client secret from its **Credentials** tab.

## Who gets in

| Setting                                       | Effect                                                                                                            |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `OIDC_USER_PROVISIONING=true` (default)       | Anyone the provider lets through gets a **member** account on first login. Admins promote them on the Users page. |
| `OIDC_ALLOWED_DOMAINS=example.com,example.at` | With provisioning: only these email domains get an account                                                        |
| `OIDC_USER_PROVISIONING=false`                | Only invited users can log in with the provider                                                                   |

Users are matched by the provider's subject identifier, not by email, so a changed email address does not create a second account.

**Existing accounts are never taken over by email.** Entra ID and AD FS do not confirm that an email address is verified, so a provider login with the same email as an existing TestFleet user does not log in as that user. Instead, invitation links offer **Continue with &lt;provider&gt;**, and a logged-in user can link their provider account in the settings.

## Single sign-on only

```ini
AUTH_PASSWORD_LOGIN=false
```

removes password login entirely: the login page shows only the provider's button, the settings have no password section, and the first-run setup link and invitations create accounts through the provider. TestFleet refuses to start with this setting unless `OIDC_ISSUER` is set, so it cannot be locked into a state without any way in.

## Trying it locally

The repository's development Compose file includes a Keycloak realm with test users:

```sh
docker compose --profile oidc up -d keycloak
OIDC_ISSUER=http://localhost:8180/realms/testfleet OIDC_CLIENT_ID=testfleet \
  OIDC_CLIENT_SECRET=testfleet-dev-secret mix phx.server
```

Users `alice`/`alice` (with a verified email) and `bob`/`bob` (without).
