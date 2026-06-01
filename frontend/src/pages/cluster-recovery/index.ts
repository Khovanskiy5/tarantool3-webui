import type { RouteRecordRaw } from 'vue-router';

export const CLUSTER_RECOVERY_ROUTE: RouteRecordRaw = {
  path: '/cluster-recovery',
  name: 'cluster-recovery',
  component: () => import('./ui/ClusterRecovery.vue'),
  meta: { role: 'admin' as const },
};
