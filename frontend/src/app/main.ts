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

app.mount('#app');

info('webui SPA mounted', { app_version: APP_VERSION });
