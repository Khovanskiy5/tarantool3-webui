import type { RouteRecordRaw } from 'vue-router';

export const DATA_EXPLORER_ROUTE: RouteRecordRaw = {
  path: '/data-explorer',
  name: 'data-explorer',
  component: () => import('./ui/DataExplorer.vue'),
  meta: { role: 'viewer' as const },
};
