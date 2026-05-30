import type { RouteRecordRaw } from 'vue-router';
export const FAILOVER_ROUTE: RouteRecordRaw = {
  path: '/failover',
  name: 'failover',
  component: () => import('./ui/Failover.vue'),
  meta: { role: 'admin' as const },
};
