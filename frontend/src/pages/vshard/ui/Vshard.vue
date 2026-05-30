<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface VshardGroup {
  name: string;
  total_buckets: number | null;
  distribution: string | null;
  rebalancer: string | null;
  status: string;
}

const groups = ref<VshardGroup[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);

const VSHARD_Q = /* GraphQL */ `
  query Vshard {
    vshard { groups { name total_buckets distribution rebalancer status } }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient().query<{ vshard: { groups: VshardGroup[] } }>(VSHARD_Q, {}).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  groups.value = res.data?.vshard?.groups ?? [];
  loading.value = false;
};

onMounted(load);
</script>

<template>
  <section class="webui-vshard">
    <h1>Vshard</h1>
    <Message v-if="!loading && groups.length === 0" severity="info" :closable="false">
      No vshard groups configured. Enable sharding in cluster config to populate this view.
    </Message>
    <p v-if="error" class="webui-vshard__error">{{ error }}</p>
    <DataTable v-if="groups.length > 0" :value="groups" :loading="loading" data-key="name" size="small" striped-rows>
      <Column field="name" header="Group" />
      <Column field="total_buckets" header="Buckets" />
      <Column header="Distribution">
        <template #body="{ data }">{{ data.distribution ?? '—' }}</template>
      </Column>
      <Column header="Rebalancer">
        <template #body="{ data }">{{ data.rebalancer ?? '—' }}</template>
      </Column>
      <Column header="Status">
        <template #body="{ data }">
          <Tag :value="data.status" :severity="data.status === 'unknown' ? 'warn' : 'info'" />
        </template>
      </Column>
    </DataTable>
  </section>
</template>

<style scoped>
.webui-vshard { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-vshard h1 { margin: 0; }
.webui-vshard__error { color: var(--p-message-error-color, #d83535); }
</style>
