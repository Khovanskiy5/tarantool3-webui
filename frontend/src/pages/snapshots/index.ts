import type { RouteRecordRaw } from 'vue-router';
export const SNAPSHOTS_ROUTE: RouteRecordRaw = {
  path: '/snapshots',
  name: 'snapshots',
  component: () => import('./ui/Snapshots.vue'),
  meta: { role: 'admin' as const },
};
