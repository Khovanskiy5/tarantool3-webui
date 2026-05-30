<script setup lang="ts">
import { storeToRefs } from 'pinia';

import { useClusterStore } from '@/entities/cluster';
import { ClusterTopology } from '@/widgets/cluster-topology';
import { SuggestionsBanner } from '@/widgets/suggestions-banner';

const store = useClusterStore();
const { servers, replicasets, selfAlias, counts, fetching, error, wsState } =
  storeToRefs(store);
</script>

<template>
  <section class="webui-cluster-page">
    <header class="webui-cluster-page__head">
      <h1 class="webui-cluster-page__title">Cluster</h1>
      <div class="webui-cluster-page__stats">
        <span><strong>{{ counts.total }}</strong> servers</span>
        <span
          :class="counts.unreachable > 0 ? 'webui-cluster-page__stat--err' : ''"
        ><strong>{{ counts.reachable }}</strong> reachable</span>
        <span><strong>{{ counts.leaders }}</strong> leaders</span>
      </div>
      <div class="webui-cluster-page__live">
        <span
          :class="[
            'webui-cluster-page__dot',
            wsState === 'open' ? 'webui-cluster-page__dot--ok' : 'webui-cluster-page__dot--err',
          ]"
        />
        <span class="webui-cluster-page__live-text">live: {{ wsState }}</span>
      </div>
    </header>

    <SuggestionsBanner />

    <p v-if="error" class="webui-cluster-page__error">
      {{ error.message }}
    </p>
    <p v-else-if="fetching && servers.length === 0" class="webui-cluster-page__loading">
      Loading…
    </p>
    <ClusterTopology
      v-else
      :replicasets="replicasets"
      :servers="servers"
      :self-alias="selfAlias"
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
  gap: 1.5rem;
  flex-wrap: wrap;
}

.webui-cluster-page__title {
  margin: 0;
  font-size: 1.4rem;
}

.webui-cluster-page__stats {
  display: flex;
  gap: 1rem;
  font-size: 0.9rem;
  color: var(--webui-text-muted);
}

.webui-cluster-page__stats strong {
  color: var(--webui-text);
  font-family: var(--webui-font-mono);
}

.webui-cluster-page__stat--err strong {
  color: var(--webui-danger);
}

.webui-cluster-page__live {
  margin-left: auto;
  font-size: 0.8rem;
  color: var(--webui-text-muted);
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
}

.webui-cluster-page__dot {
  display: inline-block;
  width: 0.5rem;
  height: 0.5rem;
  border-radius: 50%;
}

.webui-cluster-page__dot--ok {
  background: var(--webui-success);
  box-shadow: 0 0 6px rgba(63, 185, 80, 0.6);
}

.webui-cluster-page__dot--err {
  background: var(--webui-danger);
}

.webui-cluster-page__loading,
.webui-cluster-page__error {
  color: var(--webui-text-muted);
  text-align: center;
  padding: 2rem;
}

.webui-cluster-page__error {
  color: var(--webui-danger);
}
</style>
