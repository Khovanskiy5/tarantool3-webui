/**
 * urql provider bootstrap.
 *
 * The actual client construction lives in `@/shared/api/graphql/client`
 * so it has no Vue-app dependencies; this provider only installs the
 * pre-built client on the running Vue app.
 */

import { provideClient } from '@urql/vue';
import type { App } from 'vue';

import { createWebuiClient } from '@/shared/api/graphql';

export const installUrql = (app: App): void => {
  const client = createWebuiClient();
  app.runWithContext(() => provideClient(client));
};
