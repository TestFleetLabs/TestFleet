// Prefixes root-relative Markdown links with the site's base path, so content can
// link to `/ci/api/` and work both at a domain root and under /TestFleet/.
// A Sätteri mdast plugin (Astro's Markdown processor).
export default function baseLinks({ base = "/" } = {}) {
  const prefix = base.replace(/\/+$/, "")

  const rewrite = (node, ctx) => {
    const url = node.url
    if (
      prefix &&
      typeof url === "string" &&
      url.startsWith("/") &&
      !url.startsWith("//") &&
      url !== prefix &&
      !url.startsWith(`${prefix}/`)
    ) {
      ctx.setProperty(node, "url", `${prefix}${url}`)
    }
  }

  return { name: "testfleet-base-links", link: rewrite, definition: rewrite }
}
