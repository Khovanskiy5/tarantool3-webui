<script setup lang="ts">
import { onMounted, reactive } from 'vue';
import { storeToRefs } from 'pinia';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import InputText from 'primevue/inputtext';
import Button from 'primevue/button';

import { useAuditStore } from '@/entities/audit-entry';
import { downloadExportedAudit } from '@/features/audit-export';

const store = useAuditStore();
const { entries, pending, error, hasMore } = storeToRefs(store);

const filter = reactive({ user: '', action: '', scope: '' });

const buildFilter = () => ({
  user:   filter.user.trim()   || undefined,
  action: filter.action.trim() || undefined,
  scope:  filter.scope.trim()  || undefined,
});

const apply = () => { store.load(buildFilter()); };
const loadMore = () => { store.load(buildFilter(), { append: true }); };
const exportNow = () => { downloadExportedAudit(buildFilter()); };

const fmtTs = (us: number) => new Date(Math.floor(us / 1000)).toISOString();

onMounted(() => { store.load({}); });
</script>

<template>
  <section class="webui-audit">
    <header class="webui-audit__head">
      <h1>Audit log</h1>
      <Button
        size="small"
        icon="pi pi-download"
        label="Export JSON"
        @click="exportNow"
      />
    </header>

    <form class="webui-audit__filters" @submit.prevent="apply">
      <InputText v-model="filter.user" placeholder="user" />
      <InputText v-model="filter.action" placeholder="action (e.g. auth.login)" />
      <InputText v-model="filter.scope" placeholder="scope" />
      <Button type="submit" size="small" label="Apply" />
    </form>

    <p v-if="error" class="webui-audit__error">{{ error }}</p>

    <DataTable
      :value="entries"
      :loading="pending"
      data-key="id"
      size="small"
      striped-rows
      table-style="min-width: 50rem"
    >
      <Column header="When" :body-style="{ width: '14rem' }">
        <template #body="{ data }">{{ fmtTs(data.ts) }}</template>
      </Column>
      <Column field="user" header="User" :body-style="{ width: '10rem' }" />
      <Column field="action" header="Action" :body-style="{ width: '14rem' }" />
      <Column field="scope" header="Scope" :body-style="{ width: '10rem' }" />
      <Column header="Payload">
        <template #body="{ data }">
          <code v-if="data.payload" class="webui-audit__payload">{{ data.payload }}</code>
          <span v-else class="webui-audit__muted">—</span>
        </template>
      </Column>
    </DataTable>

    <div class="webui-audit__footer">
      <Button
        v-if="hasMore"
        size="small"
        text
        label="Load more"
        @click="loadMore"
      />
    </div>
  </section>
</template>

<style scoped>
.webui-audit { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-audit__head { display: flex; justify-content: space-between; align-items: center; }
.webui-audit__filters { display: flex; gap: 0.5rem; }
.webui-audit__error { color: var(--p-message-error-color, #d83535); }
.webui-audit__payload { font-family: var(--webui-font-mono); font-size: 0.8rem; }
.webui-audit__muted { color: var(--webui-text-muted); }
.webui-audit__footer { display: flex; justify-content: center; }
</style>
