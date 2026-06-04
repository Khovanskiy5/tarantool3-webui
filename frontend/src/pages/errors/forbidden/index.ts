export const FORBIDDEN_ROUTE = {
  path: '/forbidden',
  name: 'forbidden',
  component: () => import('./ui/Forbidden.vue'),
} as const;
