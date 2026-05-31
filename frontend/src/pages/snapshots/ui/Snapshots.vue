<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { restClient, RestApiError } from '@/shared/api/rest/client';

interface Entry { path: string; size: number; mtime: number; }

const dir = ref<string>('');
const entries = ref<Entry[]>([]);
const loading = ref(false);
const taking = ref(false);
const error = ref<string | null>(null);
const info = ref<string | null>(null);

const load = async () => {
  loading.value = true; error.value = null;
  try {
    const res = await restClient.get<{ dir: string; entries: Entry[] }>('/api/snapshots');
    dir.value = res.dir;
    entries.value = res.entries ?? [];
  } catch (e) {
    error.value = (e as RestApiError).message;
  } finally { loading.value = false; }
};

const take = async () => {
  taking.value = true; error.value = null; info.value = null;
  try {
    const res = await restClient.post<{
      ok: boolean;
      created: boolean;
      signature: number;
      instance: string;
      read_only: boolean;
    }>('/api/snapshots/take');
    const where = `${res.instance}${res.read_only ? ' (RO follower)' : ''}`;
    info.value = res.created
      ? `Snapshot written on ${where} at signature ${res.signature}.`
      : `Already up to date on ${where}: a snapshot for signature ${res.signature} `
        + `exists. box.snapshot() is a no-op until a new write advances the vclock.`;
    await load();
  } catch (e) {
    error.value = (e as RestApiError).message;
  } finally { taking.value = false; }
};

const fmtSize = (b: number) => {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KiB`;
  return `${(b / 1024 / 1024).toFixed(2)} MiB`;
};
const fmtTime = (t: number) => new Date(Math.floor(t * 1000)).toISOString();

onMounted(load);
</script>

<template>
  <section class="webui-snapshots">
    <header class="webui-snapshots__head">
      <div>
        <h1>Snapshots</h1>
        <p v-if="dir" class="webui-snapshots__dir">memtx_dir: <code>{{ dir }}</code></p>
      </div>
      <Button size="small" icon="pi pi-camera" label="Take snapshot" :loading="taking" @click="take" />
    </header>
    <Message v-if="info" severity="success" :closable="true" @close="info = null">{{ info }}</Message>
    <Message v-if="error" severity="error" :closable="true" @close="error = null">{{ error }}</Message>
    <DataTable :value="entries" :loading="loading" data-key="path" size="small" striped-rows>
      <Column field="path" header="File">
        <template #body="{ data }"><code>{{ data.path }}</code></template>
      </Column>
      <Column header="Size">
        <template #body="{ data }">{{ fmtSize(data.size) }}</template>
      </Column>
      <Column header="Modified">
        <template #body="{ data }">{{ fmtTime(data.mtime) }}</template>
      </Column>
    </DataTable>
  </section>
</template>

<style scoped>
.webui-snapshots { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-snapshots__head { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; }
.webui-snapshots__head h1 { margin: 0; }
.webui-snapshots__dir { margin: 0.25rem 0 0; color: var(--webui-text-muted); font-size: 0.85rem; }
</style>
