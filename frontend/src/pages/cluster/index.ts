import type { RouteRecordRaw } from 'vue-router';

export const CLUSTER_ROUTE: RouteRecordRaw = {
  path: '/cluster',
  name: 'cluster',
  component: () => import('./ui/Cluster.vue'),
};
