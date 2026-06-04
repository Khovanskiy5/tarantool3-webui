export const NOT_FOUND_ROUTE = {
  path: '/:catchAll(.*)*',
  name: 'not-found',
  component: () => import('./ui/NotFound.vue'),
} as const;
