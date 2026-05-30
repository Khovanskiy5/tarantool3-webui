/**
 * Login feature: POST /api/auth/login, then refresh the session
 * entity. The store contains both the network-state primitives
 * (`pending`, `error`) and the imperative `submit()` action.
 */

import { defineStore } from 'pinia';
import { ref } from 'vue';

import { restClient, RestApiError } from '@/shared/api/rest/client';
import { useSessionStore, type SessionUser } from '@/entities/session';
import { withTag } from '@/shared/lib/log';

const logger = withTag('auth-login');

export type LoginErrorCode =
  | 'LOGIN_FAILED'
  | 'FORBIDDEN'
  | 'RATE_LIMITED'
  | 'UNAVAILABLE'
  | 'INVALID_QUERY'
  | 'NETWORK';

export interface LoginError {
  code: LoginErrorCode;
  message: string;
}

export const useLoginStore = defineStore('auth-login', () => {
  const pending = ref(false);
  const error = ref<LoginError | null>(null);

  const submit = async (
    payload: { user: string; password: string },
  ): Promise<boolean> => {
    pending.value = true;
    error.value = null;
    try {
      const res = await restClient.post<SessionUser>(
        '/api/auth/login',
        payload,
        {
          handlers: {
            onUnauthorized: () => {},
            onForbidden: () => {},
          },
        },
      );
      // Login response shape matches /me sans `roles`; we still
      // re-probe /me so the session.roles array comes from the
      // canonical source.
      logger.info('login succeeded', { user: res.user });
      await useSessionStore().refresh();
      return true;
    } catch (err) {
      if (err instanceof RestApiError) {
        const code = (err.code as LoginErrorCode) ?? 'NETWORK';
        error.value = { code, message: err.message };
      } else {
        error.value = { code: 'NETWORK', message: (err as Error).message };
      }
      return false;
    } finally {
      pending.value = false;
    }
  };

  const reset = () => {
    error.value = null;
  };

  return { pending, error, submit, reset };
});
