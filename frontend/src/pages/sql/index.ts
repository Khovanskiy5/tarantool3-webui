import type { RouteRecordRaw } from 'vue-router';

export const SQL_ROUTE: RouteRecordRaw = {
  path: '/sql',
  name: 'sql',
  component: () => import('./ui/Sql.vue'),
  meta: { role: 'operator' as const },
};
