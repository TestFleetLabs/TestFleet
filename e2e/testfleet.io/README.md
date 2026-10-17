# testfleet.io E2E suite

Basic Playwright tests against the [testfleet.io](https://testfleet.io) landing page and docs. The suite is also a complete, working example of a TestFleet suite image: a Playwright project in Docker that writes JUnit results, an HTML report, and traces to `TestFleet_ARTIFACTS_DIR`. The [Playwright example](https://testfleet.io/suites/playwright/) in the docs explains the pattern.

## Tests

- [landing.e2e.ts](src/tests/landing.e2e.ts): the landing page, its calls to action, and its links into the docs
- [docs.e2e.ts](src/tests/docs.e2e.ts): sidebar and previous/next navigation, every sidebar page loads, the edit link, copying a code block, the 404 page
- [search.e2e.ts](src/tests/search.e2e.ts): finding a page through the search, by click and with the keyboard shortcut
- [layout.e2e.ts](src/tests/layout.e2e.ts): the theme switch, and the menu on a phone

## Configuration

| Variable     | Required | Description                                                                                                         |
| ------------ | -------- | ------------------------------------------------------------------------------------------------------------------- |
| `BASE_URL`   | no       | The site under test, for example a preview deployment. Defaults to `https://testfleet.io`. Only the origin is used. |
| `E2E_FILTER` | no       | Runs only the tests whose title matches this regular expression (Playwright's `--grep`).                            |

An invalid `BASE_URL` exits with status `2` before a browser starts.

TestFleet reserves the `TestFleet_` prefix for the variables it sets itself, such as `TestFleet_ARTIFACTS_DIR`, so a suite's own variables need a different name.

## Run locally

Requires the Node version in [.nvmrc](.nvmrc).

```sh
npm ci
npx playwright install chromium
npm run e2e
BASE_URL=http://localhost:4321 npm run e2e   # against the docs dev server
```

Reports are written to `reports/`: `junit.xml`, `playwright-report/`, and `test-results/` with screenshots and traces of failed tests.

## Run in Docker

```sh
docker build -t testfleet-e2e e2e/testfleet.io
docker run --rm --ipc=host -v "$PWD/reports:/TestFleet/artifacts" testfleet-e2e
```

The Playwright base image's version must match `@playwright/test` in [package.json](package.json): upgrade both together.

## Run in TestFleet

The [E2E suite workflow](../../.github/workflows/e2e.yml) publishes the image as `ghcr.io/testfleetlabs/testfleet-e2e`, tagged `main` and `sha-<short>`, for `linux/amd64` and `linux/arm64`. The package is private: add a registry for `ghcr.io` in TestFleet with a GitHub user and a personal access token (classic) with only `read:packages`.

Create a test definition with that image and no command: the image's entrypoint runs the suite. Give it the default 2048 MiB of shared memory, which Chromium needs. Add `BASE_URL` to the environment only to test a site other than testfleet.io.
