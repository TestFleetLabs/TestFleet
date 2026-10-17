import { expect, test } from '@playwright/test'

const repository = 'https://github.com/TestFleetLabs/TestFleet'

test.beforeEach(async ({ page }) => {
  await page.goto('/')
})

test('the home page introduces TestFleet', async ({ page }) => {
  await expect(page).toHaveTitle(/TestFleet/)
  await expect(page.getByRole('heading', { level: 1 })).toContainText(
    'Execution belongs to TestFleet',
  )
  await expect(
    page.getByRole('figure', { name: 'A run of a Playwright suite in TestFleet' }),
  ).toBeVisible()
})

test('the hero leads to the quick start', async ({ page }) => {
  await page.getByRole('link', { name: 'Quick start' }).first().click()

  await expect(page).toHaveURL('/start/quick-start/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Quick start')
})

test('the hero leads to the docs', async ({ page }) => {
  await page.getByRole('link', { name: 'Read the docs' }).click()

  await expect(page).toHaveURL('/start/introduction/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Introduction')
})

test('the header leads to the docs', async ({ page }) => {
  await page.getByRole('banner').getByRole('link', { name: 'Docs' }).click()

  await expect(page).toHaveURL('/start/introduction/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Introduction')
})

test('a section links to the part of the docs it summarizes', async ({ page }) => {
  await page.getByRole('link', { name: 'How the status is decided' }).click()

  await expect(page).toHaveURL('/guides/runs/#how-the-final-status-is-decided')
  await expect(page.locator('#how-the-final-status-is-decided')).toBeInViewport()
})

test('the call to action links to the repository', async ({ page }) => {
  await expect(page.getByRole('heading', { name: 'Give your suites a home' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'View on GitHub' })).toHaveAttribute(
    'href',
    repository,
  )
})
