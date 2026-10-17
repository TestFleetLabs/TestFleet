// Reads and validates the env vars that point the suite at testfleet.io

export interface E2eConfig {
  baseUrl: string
}

export class ConfigError extends Error {}

export const DEFAULT_BASE_URL = 'https://testfleet.io'

export function readConfig(env: NodeJS.ProcessEnv): E2eConfig {
  return {
    baseUrl: readOrigin(env, 'BASE_URL', DEFAULT_BASE_URL),
  }
}

// An unset or blank variable falls back to the default
function readOrigin(env: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const raw = env[name]?.trim() || fallback

  try {
    return new URL(raw).origin
  } catch {
    throw new ConfigError(`${name} is not a valid URL: ${raw}`)
  }
}

let cachedConfig: E2eConfig | null = null

export function getConfig(): E2eConfig {
  if (!cachedConfig) {
    cachedConfig = readConfig(process.env)
  }

  return cachedConfig
}
