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
  const input = page
    .getByRole('dialog', { name: 'Search', includeHidden: true })
    .getByRole('textbox', { name: 'Search', includeHidden: true })

  // The search button is enabled before Pagefind renders its input (on idle, via a dynamic
  // import), and opening the dialog focuses the input only if it already exists
  await expect(input).toBeAttached()

  // Lowercase: Playwright sends "K" for Control+K, and the site listens for "k"
  await page.keyboard.press('ControlOrMeta+k')

  await expect(input).toBeFocused()
})
