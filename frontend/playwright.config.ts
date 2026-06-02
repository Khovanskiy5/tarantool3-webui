/**
 * Playwright configuration for end-to-end tests.
 *
 * The suite is intentionally thin: at M0 it only verifies the
 * deployment surface (the SPA is served, the health endpoint is
 * reachable, the instance identity matches). It will grow alongside
 * feature work; new specs land under `tests/e2e/`.
 *
 * Targeting strategy:
 *   - default `baseURL` points at the first backend instance (tt-1)
 *     exposed by `docker/docker-compose.yml`. The same bundle
 *     answers the SPA, the REST API and the GraphQL endpoint.
 *   - override with `WEBUI_BASE_URL` in CI when the cluster lives
 *     somewhere else (HAProxy URL, ephemeral compose project, etc.).
 *
 * The suite does NOT launch the cluster itself. The expectation is
 * that the caller (`make e2e` / CI) brings compose up and waits for
 * the `healthy` state. Owning lifecycle here would slow down local
 * iteration where the cluster is usually already running.
 */

import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.WEBUI_BASE_URL ?? 'http://localhost:8081';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,

  // CI must not silently overwrite a test that was supposed to fail.
  forbidOnly: !!process.env.CI,

  // Retries hide flake on local laptops; CI gets one safety net.
  retries: process.env.CI ? 1 : 0,

  // Single worker keeps the dev cluster stable when tests start
  // touching the cluster state. The smoke suite is read-only and
  // could run in parallel, but the cap is set so future destructive
  // specs do not collide by default; loosen per-file via
  // `test.describe.configure({ mode: 'parallel' })`.
  workers: process.env.CI ? 1 : undefined,

  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never' }], ['list']]
    : [['html', { open: 'never' }], ['list']],

  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    // Match the SPA's default locale so date / number assertions hit
    // the same formatter the user sees.
    locale: 'ru-RU',
    timezoneId: 'Europe/Moscow',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
