import type { RouteRecordRaw } from 'vue-router';

export const ISSUES_ROUTE: RouteRecordRaw = {
  path: '/issues',
  name: 'issues',
  component: () => import('./ui/Issues.vue'),
};
