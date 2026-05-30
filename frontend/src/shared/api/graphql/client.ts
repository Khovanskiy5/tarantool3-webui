/**
 * urql GraphQL client.
 *
 * Three exchanges sit between every operation and the network:
 *   1. cacheExchange — documentCache, sufficient for an admin UI.
 *      A normalised cache (graphCache) is intentionally NOT used: it
 *      would require us to declare keys for every type up front and
 *      buys little here, because live state arrives through WebSocket
 *      anyway (cluster, issues, suggestions — see Task 21+).
 *   2. csrfErrorExchange — local to this module. Tags failures with
 *      the stable `code` from the GraphQL envelope (extensions.code)
 *      and triggers the navigation side-effects (401→/login,
 *      403→/forbidden) without coupling every Vue component to error
 *      handling.
 *   3. fetchExchange — standard.
 *
 * The CSRF token is read on each operation from `cookieTokenStore`.
 * The backend sets it when issuing the session cookie (Task 25). Until
 * that path lands, the token simply stays empty and CSRF middleware
 * is in placeholder mode on the backend.
 */

import {
  createClient,
  fetchExchange,
  type Client,
  type AnyVariables,
  type Operation,
  type OperationResult,
  type Exchange,
} from '@urql/vue';
import { pipe, map } from 'wonka';

import { GRAPHQL_PATH } from '@/shared/config';
import { withTag } from '@/shared/lib/log';

const logger = withTag('graphql');

/** Cookie-backed CSRF token storage. */
const csrfTokenStore = {
  read(): string {
    if (typeof document === 'undefined') return '';
    const match = document.cookie.match(/(?:^|;)\s*webui_csrf=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : '';
  },
};

/** Determine whether an operation is a mutation (needs CSRF). */
const isMutation = (op: Operation): boolean => op.kind === 'mutation';

/**
 * Add CSRF header on mutations.
 *
 * We treat this as an operation-level concern instead of a global
 * fetch wrapper so that hand-written `fetch` calls (REST helpers,
 * static URLs) do not accidentally rely on the same code path.
 */
const withCsrfToken = (operation: Operation): Operation => {
  if (!isMutation(operation)) return operation;
  const token = csrfTokenStore.read();
  if (!token) return operation;
  const existingHeaders = (operation.context.fetchOptions as RequestInit | undefined)?.headers ?? {};
  return {
    ...operation,
    context: {
      ...operation.context,
      fetchOptions: {
        ...(operation.context.fetchOptions as RequestInit | undefined),
        headers: {
          ...(existingHeaders as Record<string, string>),
          'x-csrf-token': token,
        },
      },
    },
  };
};

/** Side effect hooks for transport-level failures. */
export interface ErrorHandlers {
  onUnauthorized?: (op: Operation) => void;
  onForbidden?: (op: Operation) => void;
  onNetworkError?: (op: Operation, err: Error) => void;
}

const defaultHandlers: Required<ErrorHandlers> = {
  onUnauthorized: () => {
    if (typeof window === 'undefined') return;
    if (window.location.pathname !== '/login') {
      window.location.href = '/login?reason=unauthorized';
    }
  },
  onForbidden: () => {
    if (typeof window === 'undefined') return;
    if (window.location.pathname !== '/forbidden') {
      window.location.href = '/forbidden';
    }
  },
  onNetworkError: (op, err) => {
    logger.error('network error', {
      operation: op.kind,
      err: err.message,
    });
  },
};

/**
 * Inspect the result for stable transport-level error codes and run
 * the matching side-effect handler. Does NOT alter the operation
 * result; downstream consumers still see the original errors.
 */
const tapErrorCodes =
  (handlers: Required<ErrorHandlers>): Exchange =>
  ({ forward }) =>
  (ops$) =>
    pipe(
      forward(ops$),
      map((result: OperationResult<unknown, AnyVariables>) => {
        if (result.error) {
          // Network-level (fetch threw, status ≥ 500 in some flows).
          if (result.error.networkError) {
            handlers.onNetworkError(result.operation, result.error.networkError);
          }
          // Aggregate stable codes from GraphQL errors.
          for (const gqlErr of result.error.graphQLErrors ?? []) {
            const code = gqlErr.extensions?.code as string | undefined;
            if (code === 'UNAUTHORIZED' || code === 'SESSION_EXPIRED') {
              handlers.onUnauthorized(result.operation);
              break;
            }
            if (code === 'FORBIDDEN') {
              handlers.onForbidden(result.operation);
              break;
            }
            logger.warn('graphql error', {
              operation: result.operation.kind,
              code,
              message: gqlErr.message,
              request_id: gqlErr.extensions?.request_id,
            });
          }
        }
        return result;
      }),
    );

const csrfExchange: Exchange = ({ forward }) => (ops$) =>
  forward(pipe(ops$, map(withCsrfToken)));

/**
 * Build a urql client. Accepting handlers as a parameter keeps tests
 * and Storybook stories able to opt out of redirects.
 */
export const createWebuiClient = (handlers: ErrorHandlers = {}): Client => {
  const merged: Required<ErrorHandlers> = { ...defaultHandlers, ...handlers };

  return createClient({
    url: GRAPHQL_PATH,
    requestPolicy: 'cache-and-network',
    fetchOptions: {
      credentials: 'same-origin',
      headers: {
        'content-type': 'application/json',
      },
    },
    exchanges: [
      // cacheExchange (the default document cache) injects a
      // `__typename` selection into every fragment alongside the
      // top-level one that already requests it; the backend
      // graphql rock 0.x rejects `two selections into the one
      // field: __typename` instead of merging per the GraphQL
      // spec. Skip the cache for now — live state arrives over
      // WS so the cache buys little — and revisit once the rock
      // implements field-selection merging.
      csrfExchange,
      tapErrorCodes(merged),
      fetchExchange,
    ],
  });
};

export type { Client };
