---
title: Users and access
description: Set up the organization, log in, invite people, assign roles, and manage API tokens.
---

Every page of TestFleet requires a login. There is no open registration: the first admin is created with a one-time link, and everyone else is invited or comes in through [single sign-on](/operate/single-sign-on/).

## Roles

|                                                                                    | Member | Admin |
| ---------------------------------------------------------------------------------- | :----: | :---: |
| Dashboard, projects, test definitions, environments and their variables, schedules |   ✓    |   ✓   |
| Runs: run now, cancel, pin, logs, artifacts                                        |   ✓    |   ✓   |
| Their own API tokens                                                               |   ✓    |   ✓   |
| Registries                                                                         |        |   ✓   |
| Notification channels, subscriptions, and deliveries                               |        |   ✓   |
| Members: invite, change role, deactivate                                           |        |   ✓   |
| Organization: name and slug                                                        |        |   ✓   |

Registries and notification channels are admin-only because they hold the most sensitive capabilities: credentials, and requests from TestFleet to arbitrary URLs.

## The first admin

While TestFleet has no users, it writes a one-time link to its log on every start:

```sh
docker compose logs testfleet | grep "No users yet"
# No users yet. Create the first admin at https://testfleet.example.internal/setup?token=…
```

Only someone who can read the server's logs can set TestFleet up, so a fresh installation cannot be claimed by its first visitor. Once a user exists, `/setup` is gone.

The setup page also asks for the name of your **organization**, such as your company or team. Left empty, or when the first admin is created through single sign-on, it is called "Default"; an admin can rename it later.

## Your organization

Everything in TestFleet (projects, runs, registries, notification channels, and API tokens) belongs to the organization, and its pages live under the organization's slug: `https://testfleet.example.internal/acme/projects`, `…/acme/runs/1842`. Opening `/` takes you there. An installation set up before organizations existed has one called "Default", at `/default/…`.

Admins change the organization's name and slug under **Organization**. Links that contain the old slug stop working, except links to runs: `/runs/1842` always redirects to the run, so links in notifications that were already sent keep working.

## Inviting people

On **Members**, an admin invites someone by email and role. TestFleet shows the invitation link to copy, and also emails it when [SMTP](/operate/configuration/#email-smtp) is configured. The link is valid for 7 days. Opening it lets the person set a password, or link their single sign-on account with **Continue with &lt;provider&gt;**.

A pending invitation can be revoked, or replaced with a new link.

With single sign-on and `OIDC_USER_PROVISIONING=true` (the default), invitations are optional: anyone your identity provider lets through gets a member account on first login.

## Logging in

| Method                             | Available when                                 |
| ---------------------------------- | ---------------------------------------------- |
| Email and password                 | Unless `AUTH_PASSWORD_LOGIN=false`             |
| A login link by email              | SMTP is configured                             |
| Log in with your identity provider | [OIDC](/operate/single-sign-on/) is configured |

Changing your password, and creating API tokens, ask for your password again if you last logged in more than 10 minutes ago.

## Deactivating

Users are never deleted, because runs refer to them. An admin **deactivates** a user instead: they are logged out everywhere at once, their API tokens are deleted, and they cannot log in. A deactivated user can be reactivated. The last active admin cannot be demoted or deactivated.

## API tokens

Each user manages their own tokens under **Settings → API tokens**, for [CI pipelines](/ci/pipelines/) and scripts:

- A token starts with `tf_` (easy to spot for secret scanners), is shown **once** when created, and is stored only as a hash.
- It expires after 30 days, 90 days, 1 year (the default), or never.
- It acts as the user who created it, and stops working when that user is deactivated.
- The token list shows its last four characters and when it was last used. **Revoke** deletes it.

Admins cannot see or create other users' tokens; deactivating a user is how an admin cuts their tokens off. The Members page shows how many tokens each user has.

:::tip[A user for CI]
A pipeline should not break when its author leaves. Invite a dedicated user such as `ci@example.com`, accept the invitation, and create the pipeline's token as that user.
:::

## Lost admin access

If no admin can log in any more, create a fresh invitation from the server:

```sh
docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'
```

It prints a link that sets a new password (or links single sign-on) for that address, as an admin.
