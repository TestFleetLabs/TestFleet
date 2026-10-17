import { expect, test } from '@playwright/test'

test('the chosen theme applies and survives a reload', async ({ page }) => {
  await page.goto('/start/introduction/')

  await page.getByLabel('Select theme').filter({ visible: true }).selectOption('light')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

  await page.reload()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
})

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('the menu opens the sidebar', async ({ page }) => {
    await page.goto('/start/introduction/')
    const sidebar = page.getByRole('navigation', { name: 'Main' })
    await expect(sidebar).toBeHidden()

    await page.getByRole('button', { name: 'Menu' }).click()
    await sidebar.getByRole('link', { name: 'Concepts' }).click()

    await expect(page).toHaveURL('/start/concepts/')
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Concepts')
  })
})
