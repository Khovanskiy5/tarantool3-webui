/**
 * Storybook 8 global preview.
 *
 * Wires the same Vue plugins the production app uses so a story
 * renders inside a faithful environment: PrimeVue with the Aura
 * preset, Pinia, vue-i18n, and an in-memory vue-router that lets
 * router-link / useRoute() work in widget stories without leaking
 * a real History API.
 */

import type { Preview } from '@storybook/vue3';
import { setup } from '@storybook/vue3';
import { withThemeByClassName } from '@storybook/addon-themes';
import PrimeVue from 'primevue/config';
import Aura from '@primevue/themes/aura';
import { createPinia } from 'pinia';
import {
  createMemoryHistory,
  createRouter,
  type RouteRecordRaw,
} from 'vue-router';

import { i18n } from '@/shared/i18n';

import '../src/app/styles/index.css';
import 'primeicons/primeicons.css';

// Every route the sidebar links to is registered as a no-op component
// so navigating inside a story does not throw "No match for location"
// warnings into the console.
const stubRoutes: RouteRecordRaw[] = [
  { path: '/', name: 'home', component: { template: '<div />' } },
  { path: '/cluster', name: 'cluster', component: { template: '<div />' } },
  { path: '/issues', name: 'issues', component: { template: '<div />' } },
  { path: '/config-editor', name: 'config-editor', component: { template: '<div />' } },
  { path: '/schema', name: 'schema', component: { template: '<div />' } },
  { path: '/users', name: 'users', component: { template: '<div />' } },
  { path: '/failover', name: 'failover', component: { template: '<div />' } },
  { path: '/vshard', name: 'vshard', component: { template: '<div />' } },
  { path: '/metrics', name: 'metrics', component: { template: '<div />' } },
  { path: '/snapshots', name: 'snapshots', component: { template: '<div />' } },
  { path: '/console', name: 'console', component: { template: '<div />' } },
  { path: '/audit', name: 'audit', component: { template: '<div />' } },
];

setup((app) => {
  app.use(createPinia());
  app.use(i18n);
  app.use(
    createRouter({
      history: createMemoryHistory(),
      routes: stubRoutes,
    }),
  );
  app.use(PrimeVue, {
    theme: {
      preset: Aura,
      options: {
        darkModeSelector: '.webui-dark',
      },
    },
  });
});

const preview: Preview = {
  parameters: {
    // Background swatches mirror the CSS tokens in
    // src/app/styles/index.css so a story's chrome looks the same as
    // it will inside the SPA shell.
    backgrounds: {
      default: 'app',
      values: [
        { name: 'app', value: '#0e1117' },
        { name: 'elevated', value: '#161b22' },
        { name: 'white', value: '#ffffff' },
      ],
    },
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
    a11y: {
      // Axe runs on every story; reports surface in the a11y tab.
      element: '#storybook-root',
      config: {},
      options: {},
    },
    viewport: {
      viewports: {
        mobile: { name: 'Mobile', styles: { width: '375px', height: '740px' } },
        tablet: { name: 'Tablet', styles: { width: '768px', height: '1024px' } },
        laptop: { name: 'Laptop', styles: { width: '1280px', height: '800px' } },
        wide: { name: 'Wide', styles: { width: '1600px', height: '900px' } },
      },
    },
  },

  decorators: [
    // Light/dark theme toggle via @storybook/addon-themes. The dark
    // class matches the `darkModeSelector` configured for PrimeVue.
    withThemeByClassName({
      themes: {
        light: '',
        dark: 'webui-dark',
      },
      defaultTheme: 'dark',
    }),
  ],

  tags: ['autodocs'],
};

export default preview;
