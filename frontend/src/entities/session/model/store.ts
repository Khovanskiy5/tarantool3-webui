/**
 * Session entity store.
 *
 * Single source of truth for the current admin's identity in the
 * SPA. Backed by GET /api/auth/me — the store reads it on app
 * boot, when a 401/403 redirect fires, and after a successful
 * /api/auth/login. The store never invents data: empty store
 * means "no session in browser, route to /login".
 *
 * RBAC ranks mirror the backend (viewer < operator < admin <
 * superuser). The hasRole() getter answers route-guard questions
 * without leaking the rank table beyond this module.
 */

import { defineStore } from 'pinia';
import { computed, ref } from 'vue';

import { restClient, RestApiError } from '@/shared/api/rest/client';
import { withTag } from '@/shared/lib/log';

const logger = withTag('session');

export type Role = 'viewer' | 'operator' | 'admin' | 'superuser';

const ROLE_RANK: Record<Role, number> = {
  viewer: 1,
  operator: 2,
  admin: 3,
  superuser: 4,
};

export interface SessionUser {
  user: string;
  roles: Role[];
  csrf: string;
  expiresAt: number;
}

export const useSessionStore = defineStore('session', () => {
  const user = ref<SessionUser | null>(null);
  const probing = ref(false);
  const lastError = ref<string | null>(null);

  const isAuthenticated = computed(() => user.value !== null);

  const roleRank = computed(() => {
    const u = user.value;
    if (u == null) return 0;
    let best = 0;
    for (const r of u.roles) {
      const rank = ROLE_RANK[r];
      if (rank != null && rank > best) best = rank;
    }
    return best;
  });

  const hasRole = (required: Role) => roleRank.value >= ROLE_RANK[required];

  // Probe /api/auth/me. Always swallows network errors — the
  // store falls back to "logged out" so the router can redirect
  // to /login. Callers re-probe after login / logout.
  const refresh = async (): Promise<void> => {
    probing.value = true;
    lastError.value = null;
    try {
      const me = await restClient.get<SessionUser>('/api/auth/me', {
        handlers: {
          // Do not redirect on /me's own 401 — that's the
          // initial-load case and we want to land on /login
          // through the guard, not via a hard window.location.
          onUnauthorized: () => {},
        },
      });
      user.value = me;
      logger.info('session refreshed', { user: me.user, roles: me.roles });
    } catch (err) {
      if (err instanceof RestApiError && err.status === 401) {
        user.value = null;
      } else {
        logger.warn('session probe failed', { err: (err as Error).message });
        lastError.value = (err as Error).message;
      }
    } finally {
      probing.value = false;
    }
  };

  const clear = () => {
    user.value = null;
  };

  return {
    user,
    probing,
    lastError,
    isAuthenticated,
    hasRole,
    refresh,
    clear,
  };
});
