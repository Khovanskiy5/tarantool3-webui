import type { RouteRecordRaw } from 'vue-router';
export const SCHEMA_ROUTE: RouteRecordRaw = {
  path: '/schema',
  name: 'schema',
  component: () => import('./ui/Schema.vue'),
  meta: { role: 'viewer' as const },
};
