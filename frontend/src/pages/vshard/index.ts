import type { RouteRecordRaw } from 'vue-router';
export const VSHARD_ROUTE: RouteRecordRaw = {
  path: '/vshard',
  name: 'vshard',
  component: () => import('./ui/Vshard.vue'),
  meta: { role: 'admin' as const },
};
