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
  leader_name: string | null;
}

interface SPEndpoint {
  uri: string;
  status: string;
  latency_ms: number | null;
  last_error: string | null;
}

interface SPStatus {
  kind: 'etcd' | 'none' | string;
  mode: string;
  endpoints: SPEndpoint[] | null;
  lease_active: boolean | null;
  coordinator: string | null;
}

const mode = ref<string>('');
const elections = ref<Election[]>([]);
const sp = ref<SPStatus | null>(null);
const error = ref<string | null>(null);
const loading = ref(false);

const FAILOVER_Q = /* GraphQL */ `
  query Failover {
    failover {
      mode
      elections { instance state term leader_name }
    }
    failoverStateProviderStatus {
      kind mode lease_active coordinator
      endpoints { uri status latency_ms last_error }
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient().query<{
    failover: { mode: string; elections: Election[] };
    failoverStateProviderStatus: SPStatus;
  }>(FAILOVER_Q, {}).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  mode.value = res.data?.failover?.mode ?? 'unknown';
  elections.value = res.data?.failover?.elections ?? [];
  sp.value = res.data?.failoverStateProviderStatus ?? null;
  loading.value = false;
};

const sev = (state: string | null) => state === 'leader' ? 'success' : state === 'follower' ? 'info' : 'warn';
const epSev = (status: string) => status === 'ok' ? 'success' : 'danger';

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
      <Column field="leader_name" header="Leader">
        <template #body="{ data }">
          <code class="webui-failover__mono">{{ data.leader_name ?? '—' }}</code>
        </template>
      </Column>
    </DataTable>

    <section v-if="sp && sp.kind !== 'none'" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>State provider</h2>
        <Tag :value="`kind: ${sp.kind}`" severity="info" />
      </header>
      <DataTable :value="sp.endpoints ?? []" data-key="uri" size="small">
        <Column field="uri" header="Endpoint">
          <template #body="{ data }"><code>{{ data.uri }}</code></template>
        </Column>
        <Column header="Status">
          <template #body="{ data }">
            <Tag :value="data.status" :severity="epSev(data.status)" />
          </template>
        </Column>
        <Column header="Latency">
          <template #body="{ data }">
            <span v-if="data.latency_ms !== null">{{ data.latency_ms.toFixed(1) }} ms</span>
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="Error">
          <template #body="{ data }">
            <code v-if="data.last_error" class="webui-failover__err">{{ data.last_error }}</code>
            <span v-else>—</span>
          </template>
        </Column>
      </DataTable>
    </section>
  </section>
</template>

<style scoped>
.webui-failover { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-failover__head { display: flex; align-items: center; gap: 1rem; }
.webui-failover__head h1 { margin: 0; }
.webui-failover__error { color: var(--p-message-error-color, #d83535); }
.webui-failover__mono { font-family: var(--webui-font-mono); font-size: 0.8rem; }
.webui-failover__sp { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 1rem; display: flex; flex-direction: column; gap: 0.75rem; }
.webui-failover__sp-head { display: flex; align-items: center; gap: 0.75rem; }
.webui-failover__sp-head h2 { margin: 0; font-size: 1.05rem; }
.webui-failover__err { font-family: var(--webui-font-mono); font-size: 0.75rem; color: var(--p-message-error-color, #d83535); }
</style>
