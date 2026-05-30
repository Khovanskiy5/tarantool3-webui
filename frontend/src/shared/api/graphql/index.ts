export { createWebuiClient } from './client';
export type { Client, ErrorHandlers } from './client';

/**
 * Process-wide urql client singleton. The provider in
 * `@/app/providers/urql` still installs the client into the Vue
 * app for component-level composables; the stores below use this
 * shared instance so they can call client.query / .mutation
 * outside Vue setup context (pinia store factories run on the
 * first `useStore()` call, where `inject(...)` is not available
 * from the urql composable).
 */
import { createWebuiClient } from './client';
let _client: ReturnType<typeof createWebuiClient> | null = null;
export function getClient() {
  if (_client === null) _client = createWebuiClient();
  return _client;
}
