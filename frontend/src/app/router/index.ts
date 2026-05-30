/**
 * Vue Router setup.
 *
 * Routes are collected from page slices that export a ROUTE constant.
 * In Task 4 only the error pages exist plus a redirect from `/` to
 * `/cluster`, which will resolve once `pages/cluster` lands (Task 22).
 * Until then the catch-all NotFound route handles unknown URLs.
 *
 * Guards (auth, RBAC) are wired up in Task 28 once the session entity
 * store is available.
 */

import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';

import { FORBIDDEN_ROUTE } from '@/pages/errors/forbidden';
import { NETWORK_ERROR_ROUTE } from '@/pages/errors/network-error';
import { NOT_FOUND_ROUTE } from '@/pages/errors/not-found';

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    redirect: '/cluster',
  },
  // Placeholder until pages/cluster lands. Renders the not-found view
  // so navigation does not 404 silently in dev.
  {
    path: '/cluster',
    name: 'cluster',
    component: () => import('@/pages/errors/not-found/ui/NotFound.vue'),
  },
  FORBIDDEN_ROUTE,
  NETWORK_ERROR_ROUTE,
  NOT_FOUND_ROUTE,
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
  // Restore scroll on back/forward; jump to top on forward navigation.
  scrollBehavior: (_to, _from, savedPosition) => {
    if (savedPosition) return savedPosition;
    return { top: 0 };
  },
});
