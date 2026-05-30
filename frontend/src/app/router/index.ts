/**
 * Vue Router setup.
 *
 * Routes are collected from page slices that export a ROUTE
 * constant. Cluster and Issues pages land in Task 22; remaining
 * areas keep a stub until their own task ships so navigation does
 * not 404 silently.
 *
 * Guards (Task 28): a global `beforeEach` re-probes /api/auth/me
 * on first navigation, redirects unauthenticated users to /login,
 * and gates /audit, /users, /console behind RBAC.
 */

import {
  createRouter,
  createWebHistory,
  type RouteRecordRaw,
  type RouteLocationNormalized,
} from 'vue-router';

import { CLUSTER_ROUTE } from '@/pages/cluster';
import { ISSUES_ROUTE } from '@/pages/issues';
import { FORBIDDEN_ROUTE } from '@/pages/errors/forbidden';
import { NETWORK_ERROR_ROUTE } from '@/pages/errors/network-error';
import { NOT_FOUND_ROUTE } from '@/pages/errors/not-found';
import { LOGIN_ROUTE } from '@/pages/login';
import { AUDIT_ROUTE } from '@/pages/audit';
import { CONFIG_EDITOR_ROUTE } from '@/pages/config-editor';
import { SCHEMA_ROUTE } from '@/pages/schema';
import { USERS_ROUTE } from '@/pages/users';
import { FAILOVER_ROUTE } from '@/pages/failover';
import { VSHARD_ROUTE } from '@/pages/vshard';
import { METRICS_ROUTE } from '@/pages/metrics';
import { SNAPSHOTS_ROUTE } from '@/pages/snapshots';
import { CONSOLE_ROUTE } from '@/pages/console';
import { useSessionStore, type Role } from '@/entities/session';

// Per-route role gating. Routes not listed inherit `viewer`
// (the default for any logged-in user).
const ROUTE_ROLES: Record<string, Role> = {
  audit:    'admin',
  users:    'admin',
  console:  'superuser',
  snapshots: 'admin',
  failover: 'admin',
  vshard:   'admin',
};

const routes: RouteRecordRaw[] = [
  { path: '/', name: 'home', redirect: '/cluster' },
  LOGIN_ROUTE,
  CLUSTER_ROUTE,
  ISSUES_ROUTE,
  CONFIG_EDITOR_ROUTE,
  SCHEMA_ROUTE,
  USERS_ROUTE,
  FAILOVER_ROUTE,
  VSHARD_ROUTE,
  METRICS_ROUTE,
  SNAPSHOTS_ROUTE,
  CONSOLE_ROUTE,
  AUDIT_ROUTE,
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

let initialProbeDone = false;

const requiredRole = (to: RouteLocationNormalized): Role | null => {
  const fromMeta = to.meta?.role;
  if (typeof fromMeta === 'string') return fromMeta as Role;
  if (typeof to.name === 'string' && ROUTE_ROLES[to.name]) return ROUTE_ROLES[to.name];
  return null;
};

router.beforeEach(async (to) => {
  const session = useSessionStore();

  // The /me probe runs once on first nav to seed the store.
  // Subsequent navigations trust the store; logout/login both
  // call session.clear() / session.refresh() directly.
  if (!initialProbeDone) {
    initialProbeDone = true;
    await session.refresh();
  }

  if (to.meta?.public === true) return true;

  if (!session.isAuthenticated) {
    return { name: 'login', query: { next: to.fullPath } };
  }

  const required = requiredRole(to);
  if (required != null && !session.hasRole(required)) {
    return { name: 'forbidden' };
  }
  return true;
});
