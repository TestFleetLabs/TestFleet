// @ts-check
import { satteri } from "@astrojs/markdown-satteri"
import starlight from "@astrojs/starlight"
import { defineConfig } from "astro/config"

import baseLinks from "./src/plugins/base-links.mjs"

// GitHub Pages serves the site at https://testfleetlabs.github.io/TestFleet/. For a
// custom domain, build with DOCS_SITE=https://docs.example.com DOCS_BASE=/
const site = process.env.DOCS_SITE ?? "https://testfleetlabs.github.io"
const base = process.env.DOCS_BASE ?? "/TestFleet"

const repository = "https://github.com/TestFleetLabs/TestFleet"

// https://astro.build/config
export default defineConfig({
  site,
  base,
  trailingSlash: "always",
  markdown: {
    // Content links are written from the site root (/ci/api/); this adds the base.
    processor: satteri({ mdastPlugins: [baseLinks({ base })] }),
  },
  integrations: [
    starlight({
      title: "TestFleet",
      description:
        "Self-hosted scheduling, execution, and monitoring for containerized end-to-end test suites.",
      logo: { src: "./src/assets/logo.svg" },
      favicon: "/favicon.svg",
      social: [{ icon: "github", label: "GitHub", href: repository }],
      editLink: { baseUrl: `${repository}/edit/main/docs/` },
      lastUpdated: true,
      customCss: ["./src/styles/theme.css"],
      components: {
        Hero: "./src/components/Hero.astro",
      },
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Introduction", slug: "start/introduction" },
            { label: "Quick start", slug: "start/quick-start" },
            { label: "Concepts", slug: "start/concepts" },
          ],
        },
        {
          label: "Write a suite",
          items: [
            { label: "The container contract", slug: "suites/container-contract" },
            { label: "Playwright example", slug: "suites/playwright" },
            { label: "Results and artifacts", slug: "suites/results-and-artifacts" },
          ],
        },
        {
          label: "Use TestFleet",
          items: [
            { label: "Test definitions", slug: "guides/test-definitions" },
            { label: "Environments and secrets", slug: "guides/environments" },
            { label: "Schedules", slug: "guides/schedules" },
            { label: "Runs", slug: "guides/runs" },
            { label: "Registries", slug: "guides/registries" },
            { label: "Notifications", slug: "guides/notifications" },
            { label: "Users and access", slug: "guides/users" },
          ],
        },
        {
          label: "CI integration",
          items: [
            { label: "Run tests from a pipeline", slug: "ci/pipelines" },
            { label: "API reference", slug: "ci/api" },
          ],
        },
        {
          label: "Operate",
          items: [
            { label: "Install", slug: "operate/install" },
            { label: "Configuration", slug: "operate/configuration" },
            { label: "Single sign-on", slug: "operate/single-sign-on" },
            { label: "Upgrade, back up, maintain", slug: "operate/maintenance" },
            { label: "Raspberry Pi and ARM", slug: "operate/arm" },
            { label: "Security model", slug: "operate/security" },
          ],
        },
        {
          label: "Under the hood",
          items: [{ label: "How execution works", slug: "internals/execution" }],
        },
      ],
    }),
  ],
})
