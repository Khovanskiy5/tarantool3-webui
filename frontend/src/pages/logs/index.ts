import type { RouteRecordRaw } from 'vue-router';
export const LOGS_ROUTE: RouteRecordRaw = {
  path: '/logs',
  name: 'logs',
  component: () => import('./ui/Logs.vue'),
  meta: { role: 'admin' as const },
};
