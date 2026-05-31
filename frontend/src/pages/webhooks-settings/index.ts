import type { RouteRecordRaw } from 'vue-router';
export const WEBHOOKS_ROUTE: RouteRecordRaw = {
  path: '/webhooks',
  name: 'webhooks',
  component: () => import('./ui/WebhooksSettings.vue'),
  meta: { role: 'admin' as const },
};
