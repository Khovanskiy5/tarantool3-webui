/**
 * Logout feature: POST /api/auth/logout, then clear the session
 * entity and push the user back to /login. The action is
 * idempotent — if the cookie is already expired, the backend
 * still returns 204 and we still clear the local state.
 */

import { restClient } from '@/shared/api/rest/client';
import { useSessionStore } from '@/entities/session';
import { withTag } from '@/shared/lib/log';

const logger = withTag('auth-logout');

export const performLogout = async (): Promise<void> => {
  try {
    await restClient.post('/api/auth/logout', undefined, {
      handlers: { onUnauthorized: () => {}, onForbidden: () => {} },
    });
  } catch (err) {
    logger.warn('logout request failed', { err: (err as Error).message });
  } finally {
    useSessionStore().clear();
  }
};
