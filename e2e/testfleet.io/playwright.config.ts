import { defineConfig, devices } from '@playwright/test'
import { join } from 'node:path'
import { getConfig } from './src/config.ts'

// TestFleet collects everything the suite writes to TestFleet_ARTIFACTS_DIR; a local run writes to reports/
const reportDir = process.env['TestFleet_ARTIFACTS_DIR'] ?? 'reports'

export default defineConfig({
  testDir: 'src/tests',
  testMatch: '**/*.e2e.ts',
  outputDir: join(reportDir, 'test-results'),
  fullyParallel: true,
  workers: 1,
  retries: 0,
  timeout: 60000,
  expect: {
    timeout: 15000,
  },
  forbidOnly: Boolean(process.env['CI']),
  reporter: [
    ['list'],
    ['junit', { outputFile: join(reportDir, 'junit.xml') }],
    ['html', { outputFolder: join(reportDir, 'playwright-report'), open: 'never' }],
  ],
  use: {
    baseURL: getConfig().baseUrl,
    locale: 'de-AT',
    timezoneId: 'Europe/Vienna',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
})
