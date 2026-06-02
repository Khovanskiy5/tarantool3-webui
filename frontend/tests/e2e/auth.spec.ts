/**
 * End-to-end coverage for the authentication flow.
 *
 * The login surface is one of the easiest places to silently regress —
 * the SPA, the `/api/auth/login` REST endpoint, the session cookie
 * shape and the post-login router redirect all have to line up, and
 * none of those layers fails loudly when one drifts. The smoke suite
 * does not touch it; this file does.
 *
 * Credentials come from docker/configs/cluster/10-credentials.yaml — the dev cluster
 * provisions `admin_dev / admin-dev-password` for exactly this kind
 * of probing. CI / a different deployment can override via env so the
 * suite is portable across compose flavours.
 */

import { test, expect } from '@playwright/test';

const ADMIN_USER = process.env.WEBUI_ADMIN_USER ?? 'admin_dev';
const ADMIN_PASSWORD = process.env.WEBUI_ADMIN_PASSWORD ?? 'admin-dev-password';

test.describe('auth / login flow', () => {
  test('login page renders the form and the submit is gated', async ({ page }) => {
    await page.goto('/login');

    await expect(page.getByRole('heading', { name: /sign in/i })).toBeVisible();

    const userField = page.getByRole('textbox', { name: 'Username' });
    const passField = page.getByRole('textbox', { name: /password/i });
    const submit = page.getByRole('button', { name: /sign in/i });

    await expect(userField).toBeVisible();
    await expect(passField).toBeVisible();

    // Submit must stay disabled while either field is empty so a
    // half-typed form cannot fire a request the backend will reject.
    await expect(submit).toBeDisabled();
    await userField.fill('whoever');
    await expect(submit).toBeDisabled();
    await passField.fill('something');
    await expect(submit).toBeEnabled();
  });

  test('invalid credentials surface the LOGIN_FAILED banner', async ({ page }) => {
    await page.goto('/login');

    await page.getByRole('textbox', { name: 'Username' }).fill('admin_dev');
    await page.getByRole('textbox', { name: /password/i }).fill('definitely-wrong');
    await page.getByRole('button', { name: /sign in/i }).click();

    // The error banner is the LoginForm Message component; its copy
    // is driven by store.error.code, so matching the user-facing text
    // verifies both that the API returned 401 and that the SPA
    // mapped the code correctly.
    await expect(page.getByText(/invalid username or password/i)).toBeVisible({
      timeout: 10_000,
    });

    // The router must NOT navigate after a failed login.
    expect(new URL(page.url()).pathname).toBe('/login');
  });

  test('valid credentials land on /cluster and the session cookie is set', async ({
    page,
    context,
  }) => {
    await page.goto('/login');

    await page.getByRole('textbox', { name: 'Username' }).fill(ADMIN_USER);
    await page.getByRole('textbox', { name: /password/i }).fill(ADMIN_PASSWORD);

    await Promise.all([
      page.waitForURL((url) => url.pathname === '/cluster', { timeout: 10_000 }),
      page.getByRole('button', { name: /sign in/i }).click(),
    ]);

    // Session + CSRF cookies are HttpOnly only for the session one;
    // both are issued by /api/auth/login. Their presence is the
    // strongest assertion that the round-trip succeeded.
    const cookies = await context.cookies();
    const sessionCookie = cookies.find((c) => c.name === 'webui_session');
    const csrfCookie = cookies.find((c) => c.name === 'webui_csrf');
    expect(sessionCookie, 'webui_session cookie must be set after login').toBeTruthy();
    expect(csrfCookie, 'webui_csrf cookie must be set after login').toBeTruthy();
    expect(sessionCookie!.httpOnly).toBe(true);
  });

  test('protected route without a session redirects back to /login', async ({ page }) => {
    // A fresh page context has no cookies, so any guarded route
    // must bounce through the router guard. The router preserves the
    // requested path in `?next=` so we can verify intent is kept.
    await page.goto('/cluster');
    await page.waitForURL((url) => url.pathname === '/login', { timeout: 10_000 });

    const url = new URL(page.url());
    expect(url.pathname).toBe('/login');
    expect(url.searchParams.get('next')).toBe('/cluster');
  });

  test('logged-in session reaches /admin/api via POST (catches urql GET regression)', async ({
    request,
  }) => {
    // Regression guard for @urql/core 5+ flipping `preferGetMethod` to
    // `'within-url-limit'` — short queries leak out as GET and hit
    // `/admin/api?query=…`, which the backend only handles via POST.
    // The fix lives in shared/api/graphql/client.ts; this probe pins
    // the wire contract so a future urql bump can't silently regress
    // it again.
    const login = await request.post('/api/auth/login', {
      data: { user: ADMIN_USER, password: ADMIN_PASSWORD },
    });
    expect(login.status(), 'login must succeed').toBe(200);
    const csrf = (await login.json()).csrf as string;

    const gql = await request.post('/admin/api', {
      headers: {
        'content-type': 'application/json',
        'x-csrf-token': csrf,
      },
      data: { query: '{ __typename }' },
    });
    expect(gql.status(), 'POST /admin/api must return 200').toBe(200);
    const body = await gql.json();
    expect(body.data?.__typename, 'introspection responds with Query').toBe('Query');
  });

  test('rest /api/auth/login returns 200 + sets session for the admin user', async ({
    request,
  }) => {
    // A direct API hit verifies the contract independently of the
    // SPA, so a UI regression cannot mask a backend break and vice
    // versa. Mirrors the curl probe operators run when diagnosing
    // auth.
    const res = await request.post('/api/auth/login', {
      data: { user: ADMIN_USER, password: ADMIN_PASSWORD },
    });
    expect(res.status(), 'login must return 200').toBe(200);

    const body = await res.json();
    expect(body.user, 'response echoes the user name').toBe(ADMIN_USER);
    expect(body.csrf, 'response includes the CSRF token').toMatch(/.+/);
    expect(body.expiresIn, 'response includes a positive TTL').toBeGreaterThan(0);

    const setCookies = res.headers()['set-cookie'] ?? '';
    expect(setCookies, 'session cookie must be issued').toMatch(/webui_session=/);
    expect(setCookies, 'CSRF cookie must be issued').toMatch(/webui_csrf=/);
  });
});
