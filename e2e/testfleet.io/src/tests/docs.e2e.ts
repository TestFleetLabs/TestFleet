import { expect, test } from '@playwright/test'

test('the sidebar navigates between docs pages', async ({ page }) => {
  await page.goto('/start/introduction/')

  const sidebar = page.getByRole('navigation', { name: 'Main' })
  await sidebar.getByRole('link', { name: 'The container contract' }).click()

  await expect(page).toHaveURL('/suites/container-contract/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('The container contract')
  await expect(sidebar.getByRole('link', { name: 'The container contract' })).toHaveAttribute(
    'aria-current',
    'page',
  )
})

test('every page in the sidebar loads', async ({ page }) => {
  await page.goto('/start/introduction/')

  const links = page.getByRole('navigation', { name: 'Main' }).getByRole('link')
  const hrefs = await links.evaluateAll((anchors) =>
    anchors.map((a) => a.getAttribute('href') ?? ''),
  )

  expect(hrefs.length).toBeGreaterThan(10)

  for (const href of hrefs) {
    const response = await page.request.get(href)
    expect(response.status(), href).toBe(200)
  }
})

test('the previous and next links walk through the docs in order', async ({ page }) => {
  await page.goto('/start/quick-start/')

  await page.locator('a[rel="next"]').click()
  await expect(page).toHaveURL('/start/concepts/')

  await page.locator('a[rel="prev"]').click()
  await expect(page).toHaveURL('/start/quick-start/')
})

test('a docs page links to its source for editing', async ({ page }) => {
  await page.goto('/start/concepts/')

  await expect(page.getByRole('link', { name: 'Edit page' })).toHaveAttribute(
    'href',
    'https://github.com/TestFleetLabs/TestFleet/edit/main/docs/src/content/docs/start/concepts.md',
  )
})

test('a code block copies its code to the clipboard', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await page.goto('/operate/install/')

  await page.getByRole('button', { name: 'Copy to clipboard' }).first().click()

  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(copied.trim()).not.toBe('')
})

test('an unknown page answers 404', async ({ page }) => {
  const response = await page.goto('/this-page-does-not-exist/')

  expect(response?.status()).toBe(404)
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('404')
})
