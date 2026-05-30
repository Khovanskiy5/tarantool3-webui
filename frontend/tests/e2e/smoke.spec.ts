/**
 * End-to-end smoke for the M0 deployment surface.
 *
 * The point of these tests is to catch a broken release before any
 * domain-specific suite tries to find a real bug. Three checks:
 *
 *   1. The backend serves the SPA shell at `/`. Validates that the
 *      embedded assets bundle was packaged and that the static
 *      handler is wired up.
 *   2. `/api/health` answers 200 with the expected role and the
 *      instance identity (`tt-1`). Validates that the role
 *      lifecycle reached `ready` and that the heartbeat is fresh.
 *   3. The SPA can reach `/api/health` from the browser (same-
 *      origin fetch). Catches CSP, CORS, asset-base or HAProxy
 *      misconfigurations that would silently break runtime fetches
 *      even though both endpoints respond when probed in isolation.
 *
 * The suite does NOT yet assert that the instance name renders in
 * the TopBar — the cluster entity store that drives that label
 * lands in Task 17. Until then the M0 smoke verifies the same
 * identity through the health endpoint, which is what the UI will
 * consume.
 */

import { test, expect } from '@playwright/test';

const EXPECTED_INSTANCE = process.env.WEBUI_EXPECTED_INSTANCE ?? 'tt-1';

test.describe('smoke / M0 deployment', () => {
  test('serves the SPA shell at /', async ({ page }) => {
    const response = await page.goto('/');
    expect(response, 'page.goto must return a response').not.toBeNull();
    expect(response!.status(), 'SPA must respond 200 at /').toBe(200);

    // The page title comes from frontend/index.html and proves the
    // embed-assets pipeline actually packaged the build artifact.
    await expect(page).toHaveTitle(/Tarantool WebUI/i);

    // The TopBar brand is the first SPA-rendered string the user
    // sees. If JS fails to boot, this assertion fires before the
    // generic title check above can mislead us.
    await expect(
      page.getByText('Tarantool WebUI', { exact: false }).first(),
    ).toBeVisible({ timeout: 15_000 });
  });

  test('/api/health returns ready + instance identity', async ({ request }) => {
    const res = await request.get('/api/health');
    expect(res.status(), '/api/health must be 200').toBe(200);

    const body = await res.json();
    expect(body.status, 'health.status must be ok').toBe('ok');
    expect(body.role_state, 'health.role_state must be ready').toBe('ready');
    expect(body.instance, 'health.instance must match expected').toBe(EXPECTED_INSTANCE);
    expect(body.webui_version, 'webui_version must be present').toMatch(/^\d+\.\d+\.\d+/);
    expect(body.tarantool_version, 'tarantool_version must be present').toMatch(/^3\.\d+\.\d+/);
  });

  test('SPA can fetch /api/health from the browser', async ({ page }) => {
    // The fetch runs inside the page context, which means CSP, CORS,
    // base URLs and HAProxy routing all apply — the same path the
    // production SPA will take.
    await page.goto('/');
    const payload = await page.evaluate(async () => {
      const res = await fetch('/api/health', { credentials: 'same-origin' });
      return { status: res.status, body: await res.json() };
    });

    expect(payload.status, 'browser fetch of /api/health must be 200').toBe(200);
    expect(payload.body.instance, 'browser sees the same instance identity').toBe(EXPECTED_INSTANCE);
  });
});
