// Entry point of `npm run e2e`: validates the env first so a misconfigured run exits 2
// before any browser starts, then hands over to Playwright.
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ConfigError, readConfig } from './config.ts'

const CONFIG_ERROR_EXIT_CODE = 2

const projectRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

try {
  readConfig(process.env)
} catch (error) {
  if (error instanceof ConfigError) {
    console.error(`[testfleet.io] ${error.message}`)
    process.exit(CONFIG_ERROR_EXIT_CODE)
  }

  throw error
}

const args = ['test', ...process.argv.slice(2)]
const filter = process.env['E2E_FILTER']?.trim()

if (filter) {
  args.push('--grep', filter)
}

// Playwright's CLI through the current node, not the .bin shim, which is a .cmd on Windows
const playwrightCli = join(projectRoot, 'node_modules', '@playwright', 'test', 'cli.js')

const child = spawn(process.execPath, [playwrightCli, ...args], {
  cwd: projectRoot,
  stdio: 'inherit',
})

child.on('exit', (code, signal) => {
  if (signal) {
    process.exit(1)
  }

  process.exit(code ?? 1)
})
