// Links from components, which the remark plugin does not see.
export function withBase(path: string): string {
  if (/^[a-z]+:/i.test(path) || path.startsWith("#")) return path
  const base = import.meta.env.BASE_URL.replace(/\/+$/, "")
  return `${base}/${path.replace(/^\/+/, "")}`
}

export const repository = "https://github.com/TestFleetLabs/TestFleet"
export const rawFile = (path: string) =>
  `https://raw.githubusercontent.com/TestFleetLabs/TestFleet/main/${path}`
