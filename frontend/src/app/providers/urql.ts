/**
 * urql provider bootstrap (skeleton).
 *
 * The real client lives in `@/shared/api/graphql/client` and is wired
 * up in Task 8 once the dump-schema → graphql-codegen pipeline emits
 * typed operations. Until then we install a placeholder so feature
 * code can be authored without conditionally importing urql.
 */

import { provideClient, createClient, fetchExchange, cacheExchange } from '@urql/vue';
import type { App } from 'vue';

import { GRAPHQL_PATH } from '@/shared/config';

export const installUrql = (app: App): void => {
  const client = createClient({
    url: GRAPHQL_PATH,
    exchanges: [
      cacheExchange,
      // CSRF and error-mapping exchanges are added in Task 8 as the
      // backend CSRF middleware (Task 26) and the error catalog (Task
      // 22) come online. For now the chain only carries the defaults.
      fetchExchange,
    ],
    requestPolicy: 'cache-and-network',
    fetchOptions: {
      credentials: 'same-origin',
    },
  });

  // We provide the client at the app level so any component (including
  // those mounted by router-view) can `useClient()`.
  app.runWithContext(() => provideClient(client));
};
