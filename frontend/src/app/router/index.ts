/**
 * Vue Router setup.
 *
 * Routes are collected from page slices that export a ROUTE constant.
 * Cluster and Issues pages land in Task 22; remaining areas
 * (config-editor, schema, users, ...) keep a NotFound stub until
 * their own task is implemented so navigation does not 404 silently.
 *
 * Guards (auth, RBAC) are wired up in Task 28 once the session entity
 * store is available.
 */

import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';

import { CLUSTER_ROUTE } from '@/pages/cluster';
import { ISSUES_ROUTE } from '@/pages/issues';
import { FORBIDDEN_ROUTE } from '@/pages/errors/forbidden';
import { NETWORK_ERROR_ROUTE } from '@/pages/errors/network-error';
import { NOT_FOUND_ROUTE } from '@/pages/errors/not-found';

const stub = () => import('@/pages/errors/not-found/ui/NotFound.vue');

const routes: RouteRecordRaw[] = [
  { path: '/', name: 'home', redirect: '/cluster' },
  CLUSTER_ROUTE,
  ISSUES_ROUTE,
  { path: '/config-editor', name: 'config-editor', component: stub },
  { path: '/schema',        name: 'schema',        component: stub },
  { path: '/users',         name: 'users',         component: stub },
  { path: '/failover',      name: 'failover',      component: stub },
  { path: '/vshard',        name: 'vshard',        component: stub },
  { path: '/metrics',       name: 'metrics',       component: stub },
  { path: '/snapshots',     name: 'snapshots',     component: stub },
  { path: '/console',       name: 'console',       component: stub },
  { path: '/audit',         name: 'audit',         component: stub },
  FORBIDDEN_ROUTE,
  NETWORK_ERROR_ROUTE,
  NOT_FOUND_ROUTE,
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
  scrollBehavior: (_to, _from, savedPosition) => {
    if (savedPosition) return savedPosition;
    return { top: 0 };
  },
});
