<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface Webhook {
  name: string;
  type: string;
  url: string | null;
  events: string[] | null;
  enabled: boolean;
  has_secret: boolean;
  delivered: number;
  failed: number;
  retried: number;
  dead_lettered: number;
  last_error: string | null;
  last_ok_at: number | null;
}

interface QueueDepth { queue: number; dead_letter: number; }
interface DeadLetterEntry {
  id: number;
  failed_at: number;
  webhook: string;
  event_type: string | null;
  attempts: number;
  last_error: string | null;
}

const webhooks = ref<Webhook[]>([]);
const depth = ref<QueueDepth | null>(null);
const deadLetter = ref<DeadLetterEntry[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);
const info = ref<string | null>(null);
const testing = ref<string | null>(null);

const Q_ALL = /* GraphQL */ `
  query Webhooks {
    webhooks {
      webhooks {
        name type url events enabled has_secret
        delivered failed retried dead_lettered
        last_error last_ok_at
      }
    }
    webhookQueueDepth { queue dead_letter }
    webhookDeadLetter(limit: 50) {
      entries { id failed_at webhook event_type attempts last_error }
    }
  }
`;
const M_TEST = /* GraphQL */ `
  mutation TestWebhook($n: String!) {
    testWebhook(name: $n) { ok latency_ms error }
  }
`;
const M_CLEAR_DLQ = /* GraphQL */ `
  mutation ClearDLQ { clearDeadLetter { cleared } }
`;

const load = async () => {
  loading.value = true; error.value = null;
  const res = await getClient().query<{
    webhooks: { webhooks: Webhook[] };
    webhookQueueDepth: QueueDepth;
    webhookDeadLetter: { entries: DeadLetterEntry[] };
  }>(Q_ALL, {}).toPromise();
  loading.value = false;
  if (res.error) { error.value = res.error.message; return; }
  webhooks.value = res.data?.webhooks?.webhooks ?? [];
  depth.value = res.data?.webhookQueueDepth ?? null;
  deadLetter.value = res.data?.webhookDeadLetter?.entries ?? [];
};

const test = async (name: string) => {
  testing.value = name; error.value = null; info.value = null;
  const res = await getClient().mutation<{ testWebhook: { ok: boolean; latency_ms: number | null; error: string | null } }>(
    M_TEST, { n: name }
  ).toPromise();
  testing.value = null;
  if (res.error) { error.value = res.error.message; return; }
  const r = res.data?.testWebhook;
  if (r?.ok) {
    info.value = `Test delivered to ${name} (${(r.latency_ms ?? 0).toFixed(1)} ms).`;
  } else {
    error.value = `Test failed for ${name}: ${r?.error ?? 'unknown'}`;
  }
  await load();
};

const clearDLQ = async () => {
  const res = await getClient().mutation<{ clearDeadLetter: { cleared: number } }>(
    M_CLEAR_DLQ, {}
  ).toPromise();
  if (res.error) { error.value = res.error.message; return; }
  info.value = `Dead-letter cleared (${res.data?.clearDeadLetter.cleared} rows).`;
  await load();
};

const fmtTime = (ts: number | null) =>
  ts == null ? '—' : new Date(ts * 1000).toISOString().replace('T', ' ').replace(/\..+$/, ' UTC');

const typeSeverity = (t: string) =>
  t === 'slack' ? 'info' : t === 'email' ? 'warn' : t === 'discord' ? 'info' : 'secondary';

onMounted(load);
</script>

<template>
  <section class="webui-webhooks">
    <header class="webui-webhooks__head">
      <h1>Webhooks</h1>
      <div class="webui-webhooks__head-actions">
        <Button size="small" icon="pi pi-refresh" label="Reload" @click="load" :loading="loading" />
      </div>
    </header>

    <Message severity="info" :closable="false">
      Webhook definitions live in <code>roles_cfg.webui.webhooks</code> of the cluster YAML.
      Edit them via /config-editor; this page is read-only with manual test + dead-letter inspection.
    </Message>

    <Message v-if="error" severity="error" :closable="true" @close="error = null">{{ error }}</Message>
    <Message v-if="info" severity="success" :closable="true" @close="info = null">{{ info }}</Message>

    <section class="webui-webhooks__queue" v-if="depth">
      <Tag :value="`queue: ${depth.queue}`" severity="info" />
      <Tag :value="`dead-letter: ${depth.dead_letter}`"
        :severity="depth.dead_letter > 0 ? 'danger' : 'secondary'" />
      <Button v-if="depth.dead_letter > 0" size="small" outlined severity="danger"
        label="Clear dead-letter" icon="pi pi-trash" @click="clearDLQ" />
    </section>

    <DataTable :value="webhooks" :loading="loading" data-key="name" size="small" striped-rows>
      <Column field="name" header="Name" />
      <Column header="Type">
        <template #body="{ data }">
          <Tag :value="data.type" :severity="typeSeverity(data.type)" />
        </template>
      </Column>
      <Column header="Target">
        <template #body="{ data }">
          <code v-if="data.url" class="webui-webhooks__mono">{{ data.url }}</code>
          <span v-else>—</span>
        </template>
      </Column>
      <Column header="Events">
        <template #body="{ data }">
          <Tag v-for="e in (data.events ?? [])" :key="e" :value="e" severity="secondary"
            class="webui-webhooks__chip" />
        </template>
      </Column>
      <Column header="Enabled">
        <template #body="{ data }">
          <Tag :value="data.enabled ? 'yes' : 'no'" :severity="data.enabled ? 'success' : 'secondary'" />
        </template>
      </Column>
      <Column header="Secret">
        <template #body="{ data }">
          <Tag :value="data.has_secret ? 'set' : 'none'"
            :severity="data.has_secret ? 'success' : 'warn'" />
        </template>
      </Column>
      <Column header="Stats">
        <template #body="{ data }">
          <div class="webui-webhooks__stats">
            <span title="delivered">ok {{ data.delivered }}</span> ·
            <span title="failed">fail {{ data.failed }}</span> ·
            <span title="retried">retry {{ data.retried }}</span> ·
            <span title="dead-lettered">dlq {{ data.dead_lettered }}</span>
          </div>
          <small class="webui-webhooks__hint" v-if="data.last_ok_at">last ok: {{ fmtTime(data.last_ok_at) }}</small>
          <small class="webui-webhooks__err"   v-if="data.last_error">last err: <code>{{ data.last_error }}</code></small>
        </template>
      </Column>
      <Column header="Action">
        <template #body="{ data }">
          <Button size="small" icon="pi pi-send" label="Test"
            :loading="testing === data.name"
            :disabled="!data.enabled"
            @click="test(data.name)" />
        </template>
      </Column>
    </DataTable>

    <section v-if="deadLetter.length > 0" class="webui-webhooks__dead-letter">
      <h2>Dead-letter ({{ deadLetter.length }})</h2>
      <DataTable :value="deadLetter" data-key="id" size="small" striped-rows>
        <Column field="webhook" header="Webhook" />
        <Column field="event_type" header="Event" />
        <Column field="attempts" header="Attempts" />
        <Column header="Failed at">
          <template #body="{ data }">{{ fmtTime(data.failed_at) }}</template>
        </Column>
        <Column header="Last error">
          <template #body="{ data }"><code>{{ data.last_error }}</code></template>
        </Column>
      </DataTable>
    </section>

    <Message v-if="!loading && webhooks.length === 0" severity="info" :closable="false">
      No webhooks configured. Add entries under <code>roles_cfg.webui.webhooks</code> in the cluster YAML.
    </Message>
  </section>
</template>

<style scoped>
.webui-webhooks { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-webhooks__head { display: flex; align-items: center; justify-content: space-between; }
.webui-webhooks__head h1 { margin: 0; }
.webui-webhooks__queue { display: flex; gap: 0.75rem; align-items: center; }
.webui-webhooks__mono { font-family: var(--webui-font-mono); font-size: 0.78rem; word-break: break-all; }
.webui-webhooks__chip { margin: 0.1rem 0.25rem 0.1rem 0; }
.webui-webhooks__stats { font-family: var(--webui-font-mono); font-size: 0.85rem; }
.webui-webhooks__hint { display: block; color: var(--webui-text-muted); font-size: 0.72rem; }
.webui-webhooks__err  { display: block; color: var(--p-message-error-color, #d83535); font-size: 0.72rem; }
.webui-webhooks__dead-letter { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 1rem; }
.webui-webhooks__dead-letter h2 { margin: 0 0 0.5rem; font-size: 1.05rem; }
</style>
