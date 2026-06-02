/**
 * Suggestions store. Direct urql client usage for the same reason
 * as cluster / issue stores (pinia setup runs outside component
 * context).
 */

import { defineStore } from 'pinia';
import { computed, onScopeDispose, ref, shallowRef } from 'vue';

import {
  ApplyForceApplyDocument,
  ApplyRestartReplicationDocument,
  RebootstrapInstanceDocument,
  SuggestionsOverviewDocument,
  type SuggestionsOverviewQuery,
  type ApplyForceApplyMutation,
  type ApplyRestartReplicationMutation,
  type RebootstrapInstanceMutation,
} from '@/shared/api/generated';
import { getClient } from '@/shared/api/graphql';
import { wsClient } from '@/shared/api/ws';
import { withTag } from '@/shared/lib/log';

import type { SuggestionsOverview } from './types';

const log = withTag('suggestion-store');

export const useSuggestionStore = defineStore('suggestions', () => {
  const client = getClient();
  const queryData = shallowRef<SuggestionsOverviewQuery | null>(null);
  const fetching = ref(false);

  async function refresh() {
    fetching.value = true;
    try {
      const result = await client
        .query(SuggestionsOverviewDocument, {}, { requestPolicy: 'network-only' })
        .toPromise();
      if (!result.error) queryData.value = result.data ?? null;
      else log.warn('suggestions query error', { err: result.error.message });
    } finally {
      fetching.value = false;
    }
  }

  void refresh();

  const unsubMsg = wsClient.onMessage((msg) => {
    if (msg.type === 'snapshot' || msg.type === 'initial') {
      log.debug('ws -> suggestions refetch', { gen: msg.generation });
      void refresh();
    }
  });
  onScopeDispose(() => {
    unsubMsg();
  });

  const data = computed<SuggestionsOverview | null>(() => queryData.value?.suggestions ?? null);
  const total = computed<number>(() => {
    const d = data.value;
    if (!d) return 0;
    return (
      d.forceApply.length +
      d.restartReplication.length +
      d.refreshVshard.length +
      d.disableServer.length +
      d.refineUri.length +
      d.restartFailover.length +
      d.bootstrapVshard.length
    );
  });

  async function applyForceApply(instanceUuids: string[]) {
    const result = await client.mutation(ApplyForceApplyDocument, { instanceUuids }).toPromise();
    const payload = (result.data as ApplyForceApplyMutation | undefined)?.applyForceApply ?? null;
    log.info('apply force_apply', {
      ok: payload?.ok ?? false,
      unknown: payload?.unknown?.length ?? 0,
    });
    void refresh();
    return payload;
  }

  async function applyRestartReplication(instanceUuids: string[]) {
    const result = await client
      .mutation(ApplyRestartReplicationDocument, { instanceUuids })
      .toPromise();
    const payload =
      (result.data as ApplyRestartReplicationMutation | undefined)?.applyRestartReplication ?? null;
    log.info('apply restart_replication', {
      ok: payload?.ok ?? false,
      unknown: payload?.unknown?.length ?? 0,
    });
    void refresh();
    return payload;
  }

  // Destructive recovery for a follower stuck in split-brain. The
  // backend wipes WAL/snap on the target and triggers Docker's
  // restart policy; replication catches up clean from healthy peers.
  // Errors come back as urql `error` — the caller is expected to
  // surface them inline (FORBIDDEN when the target owns the queue,
  // NOT_FOUND when the alias is unknown, etc).
  async function rebootstrapInstance(alias: string) {
    const result = await client.mutation(RebootstrapInstanceDocument, { alias }).toPromise();
    if (result.error) {
      log.warn('rebootstrap failed', { alias, err: result.error.message });
      return { ok: false, alias, message: result.error.message };
    }
    const payload =
      (result.data as RebootstrapInstanceMutation | undefined)?.rebootstrapInstance ?? null;
    log.info('rebootstrap dispatched', {
      alias,
      ok: payload?.ok ?? false,
    });
    void refresh();
    return payload ?? { ok: false, alias, message: 'unknown' };
  }

  return {
    data,
    total,
    fetching,
    applyForceApply,
    applyRestartReplication,
    rebootstrapInstance,
    refresh,
  };
});
