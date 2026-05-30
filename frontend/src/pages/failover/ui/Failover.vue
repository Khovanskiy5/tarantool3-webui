<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';

import { getClient } from '@/shared/api/graphql';

interface Election {
  instance: string;
  state: string | null;
  term: number | null;
  leader_uuid: string | null;
}

const mode = ref<string>('');
const elections = ref<Election[]>([]);
const error = ref<string | null>(null);
const loading = ref(false);

const FAILOVER_Q = /* GraphQL */ `
  query Failover {
    failover {
      mode
      elections { instance state term leader_uuid }
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient().query<{ failover: { mode: string; elections: Election[] } }>(FAILOVER_Q, {}).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  mode.value = res.data?.failover?.mode ?? 'unknown';
  elections.value = res.data?.failover?.elections ?? [];
  loading.value = false;
};

const sev = (state: string | null) => state === 'leader' ? 'success' : state === 'follower' ? 'info' : 'warn';

onMounted(load);
</script>

<template>
  <section class="webui-failover">
    <header class="webui-failover__head">
      <h1>Failover</h1>
      <Tag :value="`mode: ${mode}`" severity="info" />
    </header>
    <p v-if="error" class="webui-failover__error">{{ error }}</p>
    <DataTable :value="elections" :loading="loading" data-key="instance" size="small" striped-rows>
      <Column field="instance" header="Instance" />
      <Column header="State">
        <template #body="{ data }">
          <Tag :value="data.state ?? '—'" :severity="sev(data.state)" />
        </template>
      </Column>
      <Column field="term" header="Term" />
      <Column field="leader_uuid" header="Leader UUID">
        <template #body="{ data }">
          <code class="webui-failover__mono">{{ data.leader_uuid ?? '—' }}</code>
        </template>
      </Column>
    </DataTable>
  </section>
</template>

<style scoped>
.webui-failover { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-failover__head { display: flex; align-items: center; gap: 1rem; }
.webui-failover__head h1 { margin: 0; }
.webui-failover__error { color: var(--p-message-error-color, #d83535); }
.webui-failover__mono { font-family: var(--webui-font-mono); font-size: 0.8rem; }
</style>
