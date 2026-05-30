export { default as NetworkErrorPage } from './ui/NetworkError.vue';
export const NETWORK_ERROR_ROUTE = {
  path: '/network-error',
  name: 'network-error',
  component: () => import('./ui/NetworkError.vue'),
} as const;
