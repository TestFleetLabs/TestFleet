# TestFleet docs site

The landing page and user documentation: Astro with Starlight. See [README.md](README.md) for the layout and commands. The repository's root [AGENTS.md](../AGENTS.md) still applies (never commit; provide a commit message instead).

## Content rules

- **The application is the source of truth.** Behaviour, defaults, labels, and limits must match the code in `lib/` and `config/`, and the spec in `.specs/`. Check them before documenting; do not describe planned features as existing.
- Keep the spec's names: statuses, events, fields, environment variables (`TestFleet_RUN_ID`, not `TESTFLEET_RUN_ID`).
- Write for people who use or operate TestFleet, not for its developers. Implementation details belong only in `internals/`.
- Link between pages from the site root with a trailing slash: `/ci/api/`. Never hard-code `/TestFleet/`.
- Every page has a `title` and a `description` in its frontmatter, and an entry in the sidebar in `astro.config.mjs`.
- When a change to TestFleet changes user-visible behaviour, update the matching page in the same change.

## Development

When starting the dev server, use background mode:

```
astro dev --background
```

Manage the background server with `astro dev stop`, `astro dev status`, and `astro dev logs`. Run `npm run build` before finishing: it fails on broken frontmatter, unknown sidebar slugs, and MDX errors.

Astro and Starlight documentation: https://docs.astro.build, https://starlight.astro.build
