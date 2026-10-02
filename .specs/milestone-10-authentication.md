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

`AUTH_PASSWORD_LOGIN=false` is refused at startup unless OIDC is configured, so TestFleet cannot be configured into a state without any way in. It makes TestFleet an "SSO button only" installation, like Dependency-Track behind the same identity provider: the login page shows only the OIDC button, password and magic-link logins are refused by the session controller too, the settings have no password section, and the setup and invitation pages offer only "Continue with `<provider>`" (section 7). The release command (section 8) still works: its link is an invitation.

Changing one's email address (the generator's confirmation email) is only offered with SMTP. Setting and changing one's password works while password login is available, in sudo mode (the generator's re-authentication within the last 10 minutes).

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

One provider, discovered from its issuer, configured by environment variables. The first target is Microsoft: **Entra ID** (issuer `https://login.microsoftonline.com/<tenant-id>/v2.0`) or **AD FS** on premises (issuer `https://<adfs-host>/adfs`); Keycloak is used in development.

| Variable | Notes |
|----------|-------|
| `OIDC_ISSUER` | The issuer, as the provider's discovery document names it |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | A confidential client (Entra: an app registration with a client secret) |
| `OIDC_PROVIDER_NAME` | The button label, default "single sign-on" |
| `OIDC_SCOPES` | Default `openid email profile` |
| `OIDC_EMAIL_CLAIM` | The claim that holds the email, default `email`. Entra sends `email` only for users with a mailbox or when configured as an optional claim; `preferred_username` (the UPN) is the usual alternative. AD FS sends what its issuance rules add. |
| `OIDC_USER_PROVISIONING` | Default `true`: unknown users get a member account on first login. `false`: only invited or linked users can log in with the provider (like Dependency-Track's `ALPINE_OIDC_USER_PROVISIONING`). |
| `OIDC_ALLOWED_DOMAINS` | Optional, comma-separated: only these email domains get an account on first login |

The redirect URI to register at the provider is `https://<PHX_HOST>/auth/oidc/callback`. With Entra, "Assignment required" on the enterprise application limits who can log in at all; that is the provider's decision, not TestFleet's.

**Library:** `oidcc`, the OpenID Foundation-certified implementation maintained by the Erlang Ecosystem Foundation. It validates ID tokens, nonces, and issuers, and refreshes the provider's signing keys when a token names an unknown key. TestFleet calls it directly (no `oidcc_plug`), because the callback has several modes (below). The provider configuration worker is started in the supervision tree only when OIDC is configured, with exponential backoff: its default is to stop on a failed discovery, which would take TestFleet down with an unreachable provider. Until discovery succeeds, the button answers "single sign-on is not available right now".

**Flow:** authorization code with PKCE; `state`, `nonce`, the PKCE verifier, and the mode in the session. The callback checks `state` before anything else; the token exchange checks the nonce. Claims come from the ID token.

`user_identities`: `user_id`, `issuer`, `subject`, `email` (as last seen), timestamps. Unique `(issuer, subject)` and `(user_id, issuer)`. The subject is the provider's `sub`, not the email: emails and UPNs change, `sub` does not.

**Modes.** The same flow runs for four purposes:

| Mode | Started from | On the callback |
|------|-------------|-----------------|
| `login` | the login page | the four cases below |
| `setup` | `/setup` with its token | creates the first admin with this identity, if the token is still valid and there is still no user |
| `invite` | an invitation link | links this identity to the invited user and confirms them; the link is the authorization, so `email_verified` does not matter |
| `link` | the settings, in sudo mode | links this identity to the logged-in user |

`setup` and `invite` make an "SSO button only" installation work end to end: the first admin and every invited user can get in without a password, and invitations are how existing users are matched to their provider account when the provider does not verify emails (Entra, AD FS).

In `login` mode, in order:

1. **Known identity** (`issuer`, `subject`): log that user in, unless deactivated. The identity's `email` is updated.
2. **Unknown identity, and an existing user with the same email, and the provider says `email_verified: true`:** link the identity to that user (confirming a pending invitation), and log in.
3. **Unknown identity, no user with that email:** with provisioning on and the email's domain allowed (or no domains configured), create an active, confirmed member with the identity. Otherwise refuse: "Ask an admin for an invitation", naming the allowed domains where they are the reason.
4. **Unknown identity, a user with that email, but the email is not verified by the provider:** refuse, and explain that an admin can send an invitation link, or the account can be linked in the settings after logging in another way. Entra and AD FS do not send `email_verified`; linking by email would let anyone who can get a matching address or UPN at the provider take over the account.

A token without the email claim is refused with a message naming `OIDC_EMAIL_CLAIM`.

Unlinking in the settings is allowed while another way in remains: password login is available and the user has a password, or magic links are available.

No claim grants the admin role. Admins are made by admins (or the release command).

---

## 8. Release Command

For a lost or locked-out admin account:

```sh
docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'
```

It runs in the running application (`rpc`, so the endpoint's URL is known). It creates the user as an admin if it does not exist, or makes an existing user an active admin, and prints an invitation link (section 4) that sets a new password; invitation links therefore also work for existing, active users. It works regardless of `AUTH_PASSWORD_LOGIN`, and is documented in `deploy/README.md`.

---

## 9. UI

- **Login page:** the methods of section 4 that are available, in one card. Errors never tell whether an email exists.
- **Navigation:** the user's email with a menu: settings, log out.
- **Users page** (`/users`, admin): active, invited, and deactivated users with role, login methods (password, provider), and last login; actions: invite, new link, revoke, change role, deactivate, reactivate.
- **Settings** (`/users/settings`): password; email (with SMTP); linked provider.
- **Run page and runs list:** "Started by `<email>`" for manual runs.

---

## 10. Configuration

`deploy/.env.example` and `deploy/README.md` gain `AUTH_PASSWORD_LOGIN` and the `OIDC_*` variables, the redirect URI, first-run setup, the release command, and a short guide for Entra ID and AD FS: where the issuer comes from (an existing OIDC application such as Dependency-Track shows it), the app registration, the email claim.

Development: a Keycloak container in the development `compose.yaml` (profile `oidc`) with an imported realm, a client, and two users (one with a verified email, one without), so the OIDC flow can be tried locally without a company identity provider.

---

## 11. Data Model Changes

| Change | Purpose |
|--------|---------|
| `users`, `users_tokens` (generated), plus `users.role` (checked: `admin` or `member`), `users.deactivated_at`, `users.last_login_at`, `hashed_password` nullable | Users, sessions, invitations, the Users page (sections 3, 4, 9) |
| `user_identities`: `user_id`, `issuer`, `subject`, `email`, timestamps; unique `(issuer, subject)` and `(user_id, issuer)` | OIDC (section 7) |
| `runs.triggered_by_user_id`, nullable, `on_delete: :nilify_all` | Who started a manual run (section 6) |

---

## 12. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Users and roles: `phx.gen.auth` adapted (no registration, pbkdf2, magic links only with SMTP), first-run setup, invitations, the Users page, roles, all routes protected, `triggered_by_user_id`, the release command. | – |
| B | OIDC: `oidcc`, the callback with provisioning and linking, allowed domains, linking in the settings, `AUTH_PASSWORD_LOGIN` (it only makes sense with OIDC), the Keycloak development realm, deployment docs. | A |

Each slice passes `mix precommit` on its own. The existing tests log in a user (the generator's `register_and_log_in_user` in `ConnCase`); admin pages log in an admin.

**Status (2026-09-30):** slice A is built (632 tests). In the development server, the setup link is logged on start, `/setup` is 404 without it, and every page redirects to the login.

**Status (2026-09-30):** slice B is built (674 tests). Against the Keycloak development realm, the whole flow worked end to end (driven with curl): discovery, a pushed authorization request with PKCE, the login at Keycloak, the callback with the token exchange and ID token validation, and a new member logged in. With Keycloak stopped, TestFleet started healthy and the button answered "not available"; a few seconds after Keycloak was back, logins worked without a restart. Not tried yet: a real Entra ID or AD FS.

**Status (2026-10-02): done.** Both slices are built and tested (674 tests, plus 84 Docker integration tests), and the manual walkthrough of section 14 passed, the browser login with the Keycloak profile included. Not tried yet: a real Entra ID or AD FS; anything that turns up there is fixed then.

Notes from slice B:

- **Client authentication:** `oidcc` prefers `client_secret_jwt` when the provider offers it, before `client_secret_basic` and `client_secret_post`. Keycloak offers it but rejects it for a client configured with a plain secret (a 401 already on the pushed authorization request). TestFleet passes `preferred_auth_methods: [:client_secret_basic, :client_secret_post]`, since its client always has a plain secret. Entra ID and AD FS offer `client_secret_basic` and `client_secret_post`.
- `oidcc` uses pushed authorization requests (PAR) when the provider offers them (Keycloak does); nothing to configure.
- The provider worker runs with `random_exponential` backoff (1 s to 1 min). Its default `stop` would end the worker on a failed discovery and, through restarts, TestFleet.
- The request (`state`, `nonce`, PKCE verifier, mode, token) is kept in the session under `:oidc_request` and deleted on the callback, so a callback works once. `/auth/oidc` and `/auth/oidc/callback` are open routes; `/auth/oidc/link` needs a login and sudo mode.
- The `OIDC_*` variables are read in development and production (`config/runtime.exs`); tests configure `TestFleet.OIDCStub`, which encodes the ID token's claims in the authorization code and checks the nonce and the PKCE verifier like `oidcc` would. Plain-HTTP issuers are allowed in development only.
- An OIDC login is a session login (no remember-me cookie): with single sign-on, logging in again is one click.
- The Users page shows how each user logs in (password, provider).

Notes from slice A:

- Routes: `/users/log-in`, `/users/log-in/:token` (magic link), `/users/invitations/:token`, `/setup`, `/users/settings`, and `/users` (admin). The admin pages are in the `live_session :require_admin`; the artifacts pipeline authenticates like the browser pipeline, without `accepts html`.
- The setup and invitation pages create the user, then post the email and password to `POST /users/log-in?_action=welcome` (the generator's `phx-trigger-action` pattern), so the session is created by the controller like any password login. Their forms need `method="post"`: a form for a loaded user would otherwise send `_method=put`.
- Magic links go to active users only, so the generator's "confirm by magic link" path is gone; invited users accept their invitation. A revoked invitation deletes the invited user (nothing refers to it yet).
- The setup link is logged at `warning` level by `TestFleetWeb.SetupNotice`, a task started after the endpoint; disabled in tests.
- Runs preload the user who started them with only `id` and `email`, because runs are broadcast.
- The last-admin check and the setup take PostgreSQL advisory locks, so concurrent requests cannot both pass.
- LiveViewTest has no transport socket, so the test for deactivation asserts the `disconnect` broadcast on the session topic rather than a closed LiveView.

---

## 13. Tests

- **Setup:** 404 without, with a wrong token, and once a user exists; creates an admin; two concurrent submissions create one.
- **Invitations:** the link sets a password and logs in; expired, revoked, and replaced links fail; emailed only with SMTP; invited users cannot log in before accepting.
- **Roles:** every admin page redirects members; the navigation hides them; the last admin cannot be demoted or deactivated.
- **Deactivation:** refuses login, deletes sessions, disconnects a connected LiveView.
- **Protection:** every route in the router, except the open ones of section 6, redirects without a session (one test that walks the router's routes, so a new route cannot be forgotten); the log download and artifacts answer only with a session.
- **Login methods:** magic link hidden without SMTP; `AUTH_PASSWORD_LOGIN=false` hides password login, and is refused at startup without OIDC.
- **OIDC**, against a stubbed provider (`oidcc` behind a small module that tests replace): the four `login` cases of section 7, provisioning off, allowed domains, a missing email claim, a deactivated user, a `state` mismatch, the `setup`, `invite`, and `link` modes, unlinking, and unlinking the last way in refused.
- **SSO only:** with `AUTH_PASSWORD_LOGIN=false` the login, setup, and invitation pages offer only the provider, and password and magic-link logins are refused.
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
