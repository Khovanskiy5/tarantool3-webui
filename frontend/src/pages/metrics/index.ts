import type { RouteRecordRaw } from 'vue-router';
export const METRICS_ROUTE: RouteRecordRaw = {
  path: '/metrics',
  name: 'metrics',
  component: () => import('./ui/Metrics.vue'),
};
