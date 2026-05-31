/**
 * SPA entry point.
 *
 * Stays minimal: bootstraps Vue, installs each provider in a stable
 * order, mounts the root component, and starts global error capture.
 * Order matters: error-boundary must be wired up before any plugin
 * has a chance to throw during install.
 */

import { createApp } from 'vue';
import PrimeVue from 'primevue/config';
import Aura from '@primevue/themes/aura';

import App from './App.vue';
import { router } from './router';

import { installI18n } from './providers/i18n';
import { installUrql } from './providers/urql';
import { createPiniaProvider } from './providers/pinia';
import { installErrorBoundary } from './providers/error-boundary';

import './styles/index.css';
import 'primeicons/primeicons.css';

import { info } from '@/shared/lib/log';
import { APP_VERSION } from '@/shared/config';

const app = createApp(App);

installErrorBoundary(app);

app.use(router);
app.use(createPiniaProvider());
installI18n(app);

app.use(PrimeVue, {
  theme: {
    preset: Aura,
    options: {
      darkModeSelector: '.webui-dark',
    },
  },
});

installUrql(app);

// Wait for the router's initial navigation to settle before painting
// anything. The `beforeEach` guard awaits `session.refresh()` on the
// first nav, so by the time `isReady()` resolves the SPA already
// knows whether to land on /login or on the requested admin page.
// Without this await the shell (TopBar + Sidebar) renders for a
// frame, then snaps to /login — visible as a flicker on slow networks
// or on first load against a fresh `_webui_sessions` space.
router.isReady().finally(() => {
  app.mount('#app');

  // Start the live cluster subscription right after mount. The
  // client has its own backoff loop; if /ws is unreachable
  // (production without WEBUI_DEV_ANONYMOUS_WS) the stores keep
  // working via network-only urql refetches.
  import('@/shared/api/ws').then(({ wsClient }) => {
    wsClient.connect();
    info('webui SPA mounted', { app_version: APP_VERSION });
  });
});
