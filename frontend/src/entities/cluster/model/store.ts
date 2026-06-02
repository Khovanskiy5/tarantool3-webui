/**
 * Cluster overview store.
 *
 * Drives the data feeding the /cluster page and the TopBar
 * counters. The store talks to the urql client directly through
 * the process-wide singleton because Pinia store factories run
 * outside component context — `useQuery` composables would
 * crash on a missing `inject(useClient)` otherwise.
 *
 * WS pushes trigger a refresh; the GraphQL response remains the
 * source of truth so TypeScript types stay in lockstep with the
 * schema.
 */

import { defineStore } from 'pinia';
import { computed, onScopeDispose, ref, shallowRef } from 'vue';

import {
  ClusterOverviewDocument,
  type ClusterOverviewQuery,
  type ClusterOverviewQueryVariables,
} from '@/shared/api/generated';
import { getClient } from '@/shared/api/graphql';
import { wsClient, type WsConnectionState } from '@/shared/api/ws';
import { withTag } from '@/shared/lib/log';

import {
  getReplicasets,
  getServers,
  getSelfAlias,
  countServers,
  type Replicaset,
  type Server,
} from '@/entities/cluster';

const log = withTag('cluster-store');

export const useClusterStore = defineStore('cluster', () => {
  const client = getClient();
  const data = shallowRef<ClusterOverviewQuery | null>(null);
  const fetching = ref(false);
  const error = ref<Error | null>(null);
  const wsState = ref<WsConnectionState>(wsClient.currentState());

  async function refresh() {
    fetching.value = true;
    try {
      const variables: ClusterOverviewQueryVariables = { limit: 500 };
      const result = await client
        .query(ClusterOverviewDocument, variables, { requestPolicy: 'network-only' })
        .toPromise();
      if (result.error) {
        error.value = new Error(result.error.message);
        log.warn('cluster query error', { err: result.error.message });
      } else {
        error.value = null;
        data.value = result.data ?? null;
      }
    } finally {
      fetching.value = false;
    }
  }

  void refresh();

  const unsubMsg = wsClient.onMessage((msg) => {
    if (msg.type === 'snapshot' || msg.type === 'initial') {
      log.debug('ws -> refresh', { gen: msg.generation });
      void refresh();
    }
  });
  const unsubState = wsClient.onState((state) => {
    wsState.value = state;
  });

  onScopeDispose(() => {
    unsubMsg();
    unsubState();
  });

  const cluster = computed(() => data.value?.cluster ?? null);
  const servers = computed<readonly Server[]>(() => getServers(cluster.value));
  const replicasets = computed<readonly Replicaset[]>(() => getReplicasets(cluster.value));
  const selfAlias = computed<string | null>(() => getSelfAlias(cluster.value));
  const counts = computed(() => countServers(servers.value));

  return {
    cluster,
    servers,
    replicasets,
    selfAlias,
    counts,
    fetching,
    error,
    wsState,
    refresh,
  };
});
