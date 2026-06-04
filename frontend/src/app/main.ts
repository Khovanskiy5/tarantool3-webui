/**
 * SPA entry point.
 *
 * Stays minimal: bootstraps Vue, installs each provider in a stable
 * order, mounts the root component, and starts global error capture.
 * Order matters: error-boundary must be wired up before any plugin
 * has a chance to throw during install.
 */

import { createApp, watch } from 'vue';
import PrimeVue from 'primevue/config';
import Aura from '@primevue/themes/aura';
import Tooltip from 'primevue/tooltip';
import ToastService from 'primevue/toastservice';

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
import { wsClient } from '@/shared/api/ws';
import { useSessionStore } from '@/entities/session';

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

// PrimeVue Tooltip is wired as a directive so any widget that wants a
// tooltip can use `v-tooltip` instead of the native `title` attribute.
// The native attribute has a fixed ~700ms browser delay and ignores
// theme tokens; the PrimeVue tooltip fires immediately and follows
// the Aura dark theme bridge already configured above.
app.directive('tooltip', Tooltip);

// Toast service backs the `useToast()` composable. Action results that
// are too long or too transient for an inline banner (promote/expel
// backend messages, etc.) surface as a corner toast via the single
// `<Toast />` mounted in App.vue.
app.use(ToastService);

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

  // Live cluster subscription is gated by the authenticated session:
  // the backend's WS handshake rejects the upgrade without a session
  // cookie, so an anonymous connect from the /login page would loop
  // through endless reconnect attempts and spam the console. Watch
  // session.isAuthenticated and let the WS singleton track its state.
  // The store must be resolved after `app.mount()` so Pinia is active.
  const session = useSessionStore();
  watch(
    () => session.isAuthenticated,
    (isAuth) => {
      if (isAuth) wsClient.connect();
      else wsClient.disconnect();
    },
    { immediate: true },
  );
  info('webui SPA mounted', { app_version: APP_VERSION });
});
