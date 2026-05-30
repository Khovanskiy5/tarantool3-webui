import type { RouteRecordRaw } from 'vue-router';

export const AUDIT_ROUTE: RouteRecordRaw = {
  path: '/audit',
  name: 'audit',
  component: () => import('./ui/Audit.vue'),
  meta: { role: 'admin' as const },
};
