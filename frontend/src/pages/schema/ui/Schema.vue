<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import ToggleSwitch from 'primevue/toggleswitch';
import Tag from 'primevue/tag';

import { getClient } from '@/shared/api/graphql';

interface IndexInfo { id: number; name: string; type: string | null; unique: boolean | null; parts: string[] | null; }
interface SpaceInfo { id: number; name: string; engine: string | null; row_count: number | null; indexes: IndexInfo[] | null; }

const spaces = ref<SpaceInfo[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);
const includeSystem = ref(false);
const expanded = ref<Record<string, boolean>>({});

const Q = /* GraphQL */ `
  query Spaces($sys: Boolean!) {
    spaces(include_system: $sys) {
      spaces { id name engine row_count indexes { id name type unique parts } }
    }
  }
`;

const load = async () => {
  loading.value = true; error.value = null;
  const res = await getClient().query<{ spaces: { spaces: SpaceInfo[] } }>(Q, { sys: includeSystem.value }).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  spaces.value = res.data?.spaces?.spaces ?? [];
  loading.value = false;
};

onMounted(load);
</script>

<template>
  <section class="webui-schema">
    <header class="webui-schema__head">
      <h1>Schema</h1>
      <label class="webui-schema__toggle">
        <ToggleSwitch v-model="includeSystem" @update:model-value="load" />
        <span>Show system spaces ({{ includeSystem ? 'on' : 'off' }})</span>
      </label>
    </header>
    <p v-if="error" class="webui-schema__error">{{ error }}</p>
    <DataTable
      :value="spaces"
      :loading="loading"
      data-key="id"
      size="small"
      striped-rows
      v-model:expanded-row-keys="expanded"
      :row-hover="true"
    >
      <Column expander style="width: 2rem" />
      <Column field="id" header="ID" :style="{ width: '6rem' }" />
      <Column field="name" header="Name" />
      <Column header="Engine">
        <template #body="{ data }"><Tag :value="data.engine ?? '—'" severity="info" /></template>
      </Column>
      <Column header="Rows">
        <template #body="{ data }">{{ data.row_count ?? '—' }}</template>
      </Column>
      <Column header="Indexes">
        <template #body="{ data }">{{ (data.indexes ?? []).length }}</template>
      </Column>
      <template #expansion="{ data }">
        <DataTable :value="data.indexes ?? []" data-key="id" size="small">
          <Column field="id" header="ID" :style="{ width: '4rem' }" />
          <Column field="name" header="Name" />
          <Column field="type" header="Type" />
          <Column header="Unique">
            <template #body="{ data: idx }">{{ idx.unique ? 'yes' : 'no' }}</template>
          </Column>
          <Column header="Parts">
            <template #body="{ data: idx }">
              <code>{{ (idx.parts ?? []).join(', ') }}</code>
            </template>
          </Column>
        </DataTable>
      </template>
    </DataTable>
  </section>
</template>

<style scoped>
.webui-schema { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-schema__head { display: flex; align-items: center; justify-content: space-between; }
.webui-schema__head h1 { margin: 0; }
.webui-schema__toggle { display: inline-flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; color: var(--webui-text-muted); }
.webui-schema__error { color: var(--p-message-error-color, #d83535); }
</style>
