import type { RouteRecordRaw } from 'vue-router';
export const CONFIG_EDITOR_ROUTE: RouteRecordRaw = {
  path: '/config-editor',
  name: 'config-editor',
  component: () => import('./ui/ConfigEditor.vue'),
  meta: { role: 'operator' as const },
};
