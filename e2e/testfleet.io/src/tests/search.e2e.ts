import { expect, test } from '@playwright/test'

test('a visitor finds a docs page through the search', async ({ page }) => {
  await page.goto('/start/introduction/')

  await page.getByRole('button', { name: 'Search' }).click()
  const dialog = page.getByRole('dialog', { name: 'Search' })
  await dialog.getByRole('textbox', { name: 'Search' }).fill('container contract')

  await dialog.getByRole('link', { name: 'The container contract' }).first().click()

  await expect(page).toHaveURL(/\/suites\/container-contract\//)
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('The container contract')
})

test('the search opens with the keyboard shortcut', async ({ page }) => {
  await page.goto('/start/introduction/')
  await expect(page.getByRole('button', { name: 'Search' })).toBeEnabled()

  // Lowercase: Playwright sends "K" for Control+K, and the site listens for "k"
  await page.keyboard.press('ControlOrMeta+k')

  await expect(
    page.getByRole('dialog', { name: 'Search' }).getByRole('textbox', { name: 'Search' }),
  ).toBeFocused()
})
