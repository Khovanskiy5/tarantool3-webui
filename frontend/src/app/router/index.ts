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
// SCHEMA_ROUTE is intentionally NOT imported — Task 2.5 retires the
// /schema page in favour of /data-explorer; the legacy path is kept
// as a redirect below until the next breaking cleanup.
import { DATA_EXPLORER_ROUTE } from '@/pages/data-explorer';
import { USERS_ROUTE } from '@/pages/users';
import { FAILOVER_ROUTE } from '@/pages/failover';
import { VSHARD_ROUTE } from '@/pages/vshard';
import { METRICS_ROUTE } from '@/pages/metrics';
import { SNAPSHOTS_ROUTE } from '@/pages/snapshots';
import { CONSOLE_ROUTE } from '@/pages/console';
import { BOOTSTRAP_ROUTE } from '@/pages/bootstrap';
import { WEBHOOKS_ROUTE } from '@/pages/webhooks-settings';
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
  DATA_EXPLORER_ROUTE,
  // Task 2.5: /schema is superseded by /data-explorer; keep the old
  // path as a redirect so existing bookmarks and runbook links
  // still land in the same place. The legacy Schema.vue stays in
  // the bundle for one more milestone in case we need to point
  // someone at the read-only view; remove together with the
  // route on the next breaking cleanup.
  { path: '/schema', redirect: '/data-explorer' },
  USERS_ROUTE,
  FAILOVER_ROUTE,
  VSHARD_ROUTE,
  METRICS_ROUTE,
  SNAPSHOTS_ROUTE,
  CONSOLE_ROUTE,
  BOOTSTRAP_ROUTE,
  WEBHOOKS_ROUTE,
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
