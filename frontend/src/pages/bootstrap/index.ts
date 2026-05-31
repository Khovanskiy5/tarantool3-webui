import type { RouteRecordRaw } from 'vue-router';
export const BOOTSTRAP_ROUTE: RouteRecordRaw = {
  path: '/bootstrap',
  name: 'bootstrap',
  component: () => import('./ui/Bootstrap.vue'),
  meta: { role: 'admin' as const },
};
