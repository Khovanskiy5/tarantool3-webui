import type { RouteRecordRaw } from 'vue-router';
export const CONSOLE_ROUTE: RouteRecordRaw = {
  path: '/console',
  name: 'console',
  component: () => import('./ui/Console.vue'),
  meta: { role: 'superuser' as const },
};
