<script setup lang="ts">
import { storeToRefs } from 'pinia';
import { computed, onScopeDispose, ref } from 'vue';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

import { useClusterStore } from '@/entities/cluster';
import { useSessionStore } from '@/entities/session';
import { ClusterToolbar } from '@/features/cluster-ops';
import { getClient } from '@/shared/api/graphql';
import { wsClient } from '@/shared/api/ws';
import { ClusterTopology } from '@/widgets/cluster-topology';
import { SuggestionsBanner } from '@/widgets/suggestions-banner';

const store = useClusterStore();
const { servers, replicasets, selfAlias, counts, fetching, error, wsState } = storeToRefs(store);

// Operator-toolkit affordances only for admin+. Viewers / operators
// keep the read-only topology view they had before.
const session = useSessionStore();
const showActions = computed(() => session.hasRole('admin'));

// failoverAgentStatus is sourced from etcd directly (Phase 5.11) so
// the value is global — fetch it once on mount and refresh on every
// WS snapshot tick. Pause toggles are rare, so polling the field
// alongside the existing cluster snapshot is essentially free.
const pausedUntil = ref<number | null>(null);

async function refreshPauseStatus() {
  const client = getClient();
  const res = await client
    .query<{
      failoverAgentStatus: { paused_until: number | null };
    }>(
      'query AgentPause { failoverAgentStatus { paused_until } }',
      {},
      { requestPolicy: 'network-only' },
    )
    .toPromise();
  if (!res.error) {
    pausedUntil.value = res.data?.failoverAgentStatus?.paused_until ?? null;
  }
}

void refreshPauseStatus();

const unsubMsg = wsClient.onMessage((msg) => {
  if (msg.type === 'snapshot' || msg.type === 'initial') {
    void refreshPauseStatus();
  }
});
onScopeDispose(() => unsubMsg());
</script>

<template>
  <section class="webui-cluster-page">
    <header class="webui-cluster-page__head">
      <h1 class="webui-cluster-page__title">Cluster</h1>
      <Tag :value="`${counts.total} servers`" severity="secondary" />
      <Tag
        :value="`${counts.reachable} reachable`"
        :severity="counts.unreachable > 0 ? 'danger' : 'success'"
      />
      <Tag :value="`${counts.leaders} leaders`" severity="info" />
      <!-- WebSocket status: success when the snapshot stream is live,
           danger otherwise. The text mirrors the underlying readyState
           name so it lines up with what the dev tools console shows. -->
      <Tag
        class="webui-cluster-page__live"
        :value="`live: ${wsState}`"
        :severity="wsState === 'open' ? 'success' : 'danger'"
        icon="pi pi-circle-fill"
      />
    </header>

    <SuggestionsBanner />

    <ClusterToolbar v-if="showActions" :paused-until="pausedUntil" @refresh="refreshPauseStatus" />

    <Message v-if="error" severity="error" :closable="false">
      {{ error.message }}
    </Message>
    <Message
      v-else-if="fetching && servers.length === 0"
      severity="info"
      :closable="false"
      variant="simple"
    >
      Loading cluster snapshot…
    </Message>
    <ClusterTopology
      v-else
      :replicasets="replicasets"
      :servers="servers"
      :self-alias="selfAlias"
      :show-actions="showActions"
    />
  </section>
</template>

<style scoped>
.webui-cluster-page {
  padding: 1rem 1.5rem 2rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.webui-cluster-page__head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  flex-wrap: wrap;
}

.webui-cluster-page__title {
  margin: 0;
  font-size: 1.4rem;
  /* Push the live-status tag to the far right; the other tags stay
     packed next to the title with the parent's gap. */
  margin-right: 0.75rem;
}

.webui-cluster-page__live {
  margin-left: auto;
}
</style>
