<script setup lang="ts">
import { computed } from 'vue';

import { ReplicasetCard, type Replicaset } from '@/entities/replicaset';
import type { Server } from '@/entities/cluster';

const props = defineProps<{
  replicasets: readonly Replicaset[];
  servers: readonly Server[];
  selfAlias?: string | null;
}>();

// The cluster query returns the replicaset's servers as a stripped
// projection. We want the full Server payload for the table rows,
// so we re-resolve members against the top-level servers list by
// alias. This stays an O(R×N) walk because replicaset sizes top
// out at single digits.
const serversByAlias = computed(() => {
  const map = new Map<string, Server>();
  for (const s of props.servers) map.set(s.alias, s);
  return map;
});

function membersFor(rs: Replicaset): Server[] {
  const out: Server[] = [];
  for (const m of rs.servers) {
    const full = serversByAlias.value.get(m.alias);
    if (full) out.push(full);
  }
  return out;
}
</script>

<template>
  <div class="webui-cluster-topology">
    <ReplicasetCard
      v-for="rs in replicasets"
      :key="rs.name"
      :replicaset="rs"
      :servers="membersFor(rs)"
      :self-alias="selfAlias"
    />
    <p v-if="replicasets.length === 0" class="webui-cluster-topology__empty">
      No replicasets reported yet.
    </p>
  </div>
</template>

<style scoped>
.webui-cluster-topology {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.webui-cluster-topology__empty {
  padding: 1.5rem;
  text-align: center;
  color: var(--webui-text-muted);
  border: 1px dashed var(--webui-border);
  border-radius: var(--webui-radius);
}
</style>
