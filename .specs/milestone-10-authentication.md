# TestFleet — Milestone 10: Authentication

## 1. Purpose

Until now every page of TestFleet is open to anyone who can reach it: its secrets never reach the browser, but anyone can run containers, add registries, and point webhooks at internal addresses. Milestone 10 puts every page behind a login, and splits what users may do into two roles.

```text
first start, no users → /setup (one-time token from the log) → first admin
admin → invite (link, emailed when SMTP is set) → member sets a password
anyone with an account at the identity provider → "Log in with <provider>" → member
```

The main spec planned single sign-on only (section 36: "rather than with separate TestFleet passwords", and Milestone 1, deferred on 2026-09-26). **Deviation:** TestFleet also has its own password login. An installation without an identity provider, or before one is configured, must still be usable, and OIDC stays optional configuration. The main spec is updated accordingly.

---

## 2. Scope

### In scope

- Users, sessions, and passwords, generated with `mix phx.gen.auth` and adapted
- First-run setup with a one-time token
- Invitations instead of open registration
- Two roles: admin and member
- Every page, the log download, and artifacts behind a login; admin pages behind the admin role
- `runs.triggered_by_user_id`
- Magic-link login when SMTP is configured
- OIDC login with one generic provider (discovery), provisioning, and account linking
- A release command to invite an admin, for a lost admin account

### Out of scope

| What | Milestone |
|------|-----------|
| API tokens (per user, hashed, revocable) | API (main spec section 40) |
| Read-only viewer role, per-project permissions | later (main spec section 36, "RBAC") |
| Roles or groups from the identity provider's claims | later |
| Several OIDC providers at once, SAML, LDAP | later |
| Per-user notification preferences | later (Milestone 8, section 2) |
| Rate limiting of login attempts | later; the deployment is internal (Milestone 9, section 8) |
| Audit log | later |

---

## 3. Users

Generated with `mix phx.gen.auth Accounts User users --live` in the `TestFleet.Accounts` context (main spec section 5). The scope is `TestFleet.Accounts.Scope`, assigned as `current_scope`, as the project's Phoenix rules expect.

`users`: `email` (citext, unique), `hashed_password` (nullable: invited users and OIDC-only users have none), `confirmed_at`, `role` (`admin` or `member`, default `member`), `deactivated_at`, timestamps.

Password hashing uses `pbkdf2_elixir` (the generator's choice on Windows): it needs no C compiler, so development on Windows and the Linux image use the same library.

Users are never deleted, because runs refer to them. An admin **deactivates** a user instead: login is refused, their sessions are deleted, and their open LiveViews are disconnected (`UserAuth.disconnect_sessions/1`). A deactivated user can be reactivated.

The last active admin can neither be demoted nor deactivated.

---

## 4. Getting In

### First-run setup

While there is no user, TestFleet logs on every start:

```text
No users yet. Create the first admin at https://<PHX_HOST>/setup?token=<token>
```

The token is random, kept in memory only, and new on every start. `/setup` without the token, with a wrong one, or once a user exists answers 404. It asks for an email and a password, and creates an active, confirmed admin in a transaction that checks again that no user exists. Because only someone who can read the container log can set up TestFleet, an empty installation cannot be taken over by the first visitor.

### Invitations

There is no open registration: the generator's registration page is removed.

An admin invites someone by email and role on the Users page. That creates the user, without a password, and an invitation token (in `users_tokens`, context `invite`, valid 7 days, hashed like the generator's other tokens). The admin sees the link once, to copy. When SMTP is configured, it is also emailed. Opening the link asks for a password; saving it confirms the user and logs them in. An admin can create a new link for a pending invitation, which invalidates the old one, or revoke it.

### Login methods

| Method | Available when |
|--------|----------------|
| Email and password | `AUTH_PASSWORD_LOGIN` is not `false` (default: available) |
| Magic link (the generator's default) | SMTP is configured (`SMTP_HOST`, Milestone 8) |
| "Log in with `<OIDC_PROVIDER_NAME>`" | OIDC is configured (section 7) |

`AUTH_PASSWORD_LOGIN=false` is refused at startup unless OIDC is configured, so TestFleet cannot be configured into a state without any way in. It hides password and magic-link login, and the release command (section 8) still works.

Changing one's email address (the generator's confirmation email) is only offered with SMTP. Setting and changing one's password always works, in sudo mode (the generator's re-authentication within the last 10 minutes).

---

## 5. Roles

| Area | Member | Admin |
|------|--------|-------|
| Dashboard, projects, test definitions, environments and their variables, schedules | ✓ | ✓ |
| Runs: run now, cancel, pin, logs, artifacts | ✓ | ✓ |
| Registries | – | ✓ |
| Notification channels and subscriptions, delivery log | – | ✓ |
| Users: invite, change role, deactivate | – | ✓ |

Admin pages are in their own `live_session` with an `on_mount` that requires the admin role; a member opening one is redirected to the dashboard with a flash. The navigation hides what the user cannot open. Registries and channels hold the most dangerous capabilities (credentials, and outgoing requests to arbitrary URLs), so this closes the known risk of Milestone 8, section 4, for members.

Contexts keep their functions without a scope for now. The roles are enforced at the edge (router, `on_mount`, controllers), because no data belongs to a user yet.

---

## 6. Protected Routes

- All LiveViews are in `live_session`s with `on_mount` `:require_authenticated` (and `:require_admin`); `current_scope` is passed to `<Layouts.app>`.
- The log download (`/runs/:id/log`) and artifacts (`/runs/:id/artifacts/*name`) require a session. The `:artifacts` pipeline gains `fetch_session` and the authentication plug; it still does not require `accepts html`.
- Open: `/health`, the login pages, `/setup` (with its token), invitation links, the OIDC callback, static assets.
- An unauthenticated request is redirected to the login page and returns to the requested page after login.

`runs.triggered_by_user_id` (nullable, `on_delete: :nilify_all`) is set for "Run now" (main spec section 7). The run page and the runs list show who started a manual run. Scheduled runs have no user; API runs will have the token's owner.

---

## 7. OIDC

One provider, configured by environment variables:

| Variable | Notes |
|----------|-------|
| `OIDC_ISSUER` | Discovery base URL, for example `https://keycloak.example/realms/company` |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | A confidential client |
| `OIDC_PROVIDER_NAME` | The button label, default "single sign-on" |
| `OIDC_ALLOWED_DOMAINS` | Optional, comma-separated: only these email domains get an account on first login |

The redirect URI to register at the provider is `https://<PHX_HOST>/auth/oidc/callback`.

**Library:** `oidcc` with `oidcc_plug`, the OpenID Foundation-certified implementation maintained by the Erlang Ecosystem Foundation. It validates ID tokens, nonces, and issuers, and refreshes the provider's signing keys. The provider configuration worker is started in the supervision tree only when OIDC is configured. An unreachable provider must not stop TestFleet: the worker retries, and the button shows an error until discovery succeeds.

**Flow:** authorization code with PKCE; `state` and `nonce` in the session. Scopes `openid email profile`.

`user_identities`: `user_id`, `issuer`, `subject`, `email` (as last seen), timestamps. Unique `(issuer, subject)`. A user can have one identity per issuer.

On the callback, in order:

1. **Known identity** (`issuer`, `subject`): log that user in, unless deactivated.
2. **Unknown identity, and an existing user with the same email, and the provider says `email_verified: true`:** link the identity to that user, and log in.
3. **Unknown identity, no user with that email:** create an active, confirmed member with the identity, if the email's domain is allowed (or no domains are configured). Otherwise refuse, naming the allowed domains.
4. **Unknown identity, a user with that email, but the email is not verified by the provider:** refuse, and explain that the account can be linked in the settings after logging in another way. Some providers (Microsoft Entra ID among them) do not send `email_verified`; linking by email would then let anyone with a matching address take over the account.

In the settings, a logged-in user can link the provider (the same flow, in linking mode, after sudo mode) or unlink it, as long as another way in remains (a password, or SMTP for magic links).

No claim grants the admin role. Admins are made by admins (or the release command).

---

## 8. Release Command

For a lost or locked-out admin account:

```sh
docker compose exec testfleet bin/testfleet eval 'TestFleet.Release.invite_admin("ops@example.com")'
```

It creates the user as an admin if it does not exist, or makes an existing user an active admin, and prints an invitation link (section 4) that sets a new password. It works regardless of `AUTH_PASSWORD_LOGIN`, and is documented in `deploy/README.md`.

---

## 9. UI

- **Login page:** the methods of section 4 that are available, in one card. Errors never tell whether an email exists.
- **Navigation:** the user's email with a menu: settings, log out.
- **Users page** (`/users`, admin): active, invited, and deactivated users with role, login methods (password, provider), and last login; actions: invite, new link, revoke, change role, deactivate, reactivate.
- **Settings** (`/users/settings`): password; email (with SMTP); linked provider.
- **Run page and runs list:** "Started by `<email>`" for manual runs.

---

## 10. Configuration

`deploy/.env.example` and `deploy/README.md` gain `AUTH_PASSWORD_LOGIN` and the `OIDC_*` variables, the redirect URI, first-run setup, and the release command.

Development: a Keycloak container in the development `compose.yaml` (profile `oidc`) with an imported realm, a client, and two users (one with a verified email, one without), so the OIDC flow can be tried locally without a company identity provider.

---

## 11. Data Model Changes

| Change | Purpose |
|--------|---------|
| `users`, `users_tokens` (generated), plus `users.role`, `users.deactivated_at`, `hashed_password` nullable | Users, sessions, invitations (sections 3, 4) |
| `user_identities`: `user_id`, `issuer`, `subject`, `email`, timestamps; unique `(issuer, subject)` and `(user_id, issuer)` | OIDC (section 7) |
| `runs.triggered_by_user_id`, nullable, `on_delete: :nilify_all` | Who started a manual run (section 6) |

---

## 12. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Users and roles: `phx.gen.auth` adapted (no registration, pbkdf2, magic links only with SMTP), first-run setup, invitations, the Users page, roles, all routes protected, `triggered_by_user_id`, the release command, `AUTH_PASSWORD_LOGIN`. | – |
| B | OIDC: `oidcc`, the callback with provisioning and linking, allowed domains, linking in the settings, the Keycloak development realm, deployment docs. | A |

Each slice passes `mix precommit` on its own. The existing tests log in a user (the generator's `register_and_log_in_user` in `ConnCase`); admin pages log in an admin.

---

## 13. Tests

- **Setup:** 404 without, with a wrong token, and once a user exists; creates an admin; two concurrent submissions create one.
- **Invitations:** the link sets a password and logs in; expired, revoked, and replaced links fail; emailed only with SMTP; invited users cannot log in before accepting.
- **Roles:** every admin page redirects members; the navigation hides them; the last admin cannot be demoted or deactivated.
- **Deactivation:** refuses login, deletes sessions, disconnects a connected LiveView.
- **Protection:** every route in the router, except the open ones of section 6, redirects without a session (one test that walks the router's routes, so a new route cannot be forgotten); the log download and artifacts answer only with a session.
- **Login methods:** magic link hidden without SMTP; `AUTH_PASSWORD_LOGIN=false` hides password login, and is refused at startup without OIDC.
- **OIDC**, against a stubbed token exchange (`oidcc` behind a small module that tests replace): the four cases of section 7, allowed domains, a deactivated user, `state` and `nonce` mismatches, linking and unlinking in the settings, unlinking the last way in refused.
- **Runs:** "Run now" sets `triggered_by_user_id`; scheduled runs leave it empty.
- **Release command:** creates or promotes an admin and returns a working link.

---

## 14. Done

Milestone 10 is done when both slices pass `mix precommit`, the Docker tests still pass, and a manual walkthrough works:

1. A fresh production stack logs the setup link; `/setup` without the token is 404; with it, the first admin is created.
2. The admin invites a member; without SMTP, the copied link sets the member's password. The member sees no Registries, Notifications, or Users, and gets redirected from their URLs.
3. The member starts a run; the run page shows who started it.
4. The admin deactivates the member while the member has a run page open: it disconnects, and login is refused.
5. With the Keycloak profile: the verified user logs in and becomes a member; the unverified user whose email already exists is refused with the explanation, then links the provider in the settings after a password login.
6. `TestFleet.Release.invite_admin/1` restores access to a stack whose admin password is lost.
