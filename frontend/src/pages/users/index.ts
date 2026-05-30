import type { RouteRecordRaw } from 'vue-router';
export const USERS_ROUTE: RouteRecordRaw = {
  path: '/users',
  name: 'users',
  component: () => import('./ui/Users.vue'),
  meta: { role: 'admin' as const },
};
