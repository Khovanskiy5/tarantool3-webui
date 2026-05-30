import type { RouteRecordRaw } from 'vue-router';

export const LOGIN_ROUTE: RouteRecordRaw = {
  path: '/login',
  name: 'login',
  component: () => import('./ui/Login.vue'),
  meta: { public: true, hideShell: true },
};
