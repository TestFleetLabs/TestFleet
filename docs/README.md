# TestFleet website and documentation

The landing page and the user documentation, built with [Astro](https://astro.build) and [Starlight](https://starlight.astro.build). Published to GitHub Pages by [`.github/workflows/docs.yml`](../.github/workflows/docs.yml).

Requires Node.js 22 or later.

```sh
cd docs
npm ci
npm run dev        # http://localhost:4321/TestFleet/
npm run build      # into dist/
npm run preview    # serve dist/
```

## Layout

```text
docs/
├── astro.config.mjs            site, base path, sidebar
├── public/                     copied as-is (favicon)
└── src/
    ├── content/docs/           the pages, Markdown or MDX; the path is the URL
    │   └── index.mdx           the landing page (splash template)
    ├── components/
    │   ├── Hero.astro          replaces Starlight's hero on the landing page
    │   └── landing/            the landing page's sections
    ├── plugins/                remark plugin that adds the base path to links
    └── styles/theme.css        colours, light and dark
```

A new page needs a file in `src/content/docs/` and an entry in the `sidebar` of `astro.config.mjs`.

## Links

Write links between pages from the site root, with a trailing slash: `[API reference](/ci/api/)`. The site is served under `/TestFleet/` on GitHub Pages; a remark plugin adds that base to Markdown links, and components use `withBase()` from `src/lib/links.ts`.

For a custom domain, build with `DOCS_SITE=https://docs.example.com DOCS_BASE=/`.
