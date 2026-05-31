<script setup lang="ts">
import { onMounted, ref, computed } from 'vue';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';
import { YamlEditor } from '@/widgets/yaml-editor';

interface CurrentCfg { yaml: string; revision: number | null; source: string; }
interface DiffOp { op: string; path: string; from?: string | null; to?: string | null; }
interface PrepareRes {
  prepared_id: string;
  expires_at: number;
  diff: DiffOp[] | null;
  warnings: { path: string; message: string }[] | null;
}
interface CommitRes { revision: number; applied: boolean; message: string | null; }

const yaml = ref('');
const source = ref('');
const revision = ref<number | null>(null);
const loading = ref(false);
const validating = ref(false);
const preparing = ref(false);
const committing = ref(false);
const error = ref<string | null>(null);
const info = ref<string | null>(null);
const validationIssues = ref<{ path: string; message: string }[]>([]);
const preparedId = ref<string | null>(null);
const diff = ref<DiffOp[]>([]);

const Q_CURRENT = /* GraphQL */ `query Cfg { config { yaml revision source } }`;
const M_VALIDATE = /* GraphQL */ `
  mutation Validate($yaml: String!) {
    validateConfig(yaml: $yaml) { issues { path message } }
  }
`;
const M_PROPOSE = /* GraphQL */ `
  mutation Propose($yaml: String!) {
    proposeConfig(yaml: $yaml) {
      prepared_id expires_at
      diff { op path from to }
      warnings { path message }
    }
  }
`;
const M_COMMIT = /* GraphQL */ `
  mutation Commit($id: String!) {
    commitConfig(prepared_id: $id) { revision applied message }
  }
`;
const M_ABORT = /* GraphQL */ `
  mutation Abort($id: String!) {
    abortConfig(prepared_id: $id) { applied message }
  }
`;

const load = async () => {
  loading.value = true; error.value = null;
  const res = await getClient().query<{ config: CurrentCfg }>(Q_CURRENT, {}).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  yaml.value = res.data?.config?.yaml ?? '';
  source.value = res.data?.config?.source ?? '';
  revision.value = res.data?.config?.revision ?? null;
  loading.value = false;
};

const validate = async () => {
  validating.value = true; error.value = null; info.value = null;
  validationIssues.value = [];
  const res = await getClient().mutation<{ validateConfig: { issues: { path: string; message: string }[] } }>(
    M_VALIDATE, { yaml: yaml.value },
  ).toPromise();
  if (res.error) { error.value = res.error.message; validating.value = false; return; }
  validationIssues.value = res.data?.validateConfig?.issues ?? [];
  if (validationIssues.value.length === 0) info.value = 'No validation issues.';
  validating.value = false;
};

const preview = async () => {
  preparing.value = true; error.value = null; info.value = null; diff.value = [];
  const res = await getClient().mutation<{ proposeConfig: PrepareRes }>(
    M_PROPOSE, { yaml: yaml.value },
  ).toPromise();
  if (res.error) { error.value = res.error.message; preparing.value = false; return; }
  const r = res.data?.proposeConfig;
  if (r) {
    preparedId.value = r.prepared_id;
    diff.value = r.diff ?? [];
    info.value = `Prepared ${r.prepared_id} (expires at ${new Date(r.expires_at * 1000).toLocaleTimeString()}). ${diff.value.length} diff ops.`;
  }
  preparing.value = false;
};

const apply = async () => {
  if (preparedId.value == null) return;
  committing.value = true; error.value = null;
  const res = await getClient().mutation<{ commitConfig: CommitRes }>(
    M_COMMIT, { id: preparedId.value },
  ).toPromise();
  if (res.error) { error.value = res.error.message; committing.value = false; return; }
  const r = res.data?.commitConfig;
  if (r?.applied) {
    info.value = r.message ?? `Applied. New revision ${r.revision}.`;
    preparedId.value = null;
    diff.value = [];
    await load();
  } else {
    error.value = r?.message ?? 'commit not applied';
  }
  committing.value = false;
};

const abort = async () => {
  if (preparedId.value == null) return;
  await getClient().mutation(M_ABORT, { id: preparedId.value }).toPromise();
  preparedId.value = null; diff.value = []; info.value = 'Prepared state discarded.';
};

const download = async () => {
  try {
    const blob = await fetch('/api/config/download', { credentials: 'same-origin' }).then(r => r.blob());
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = 'cluster.yaml';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  } catch (e) { error.value = (e as Error).message; }
};

const hasPrepared = computed(() => preparedId.value != null);

onMounted(load);
</script>

<template>
  <section class="webui-cfg">
    <header class="webui-cfg__head">
      <div>
        <h1>Configuration editor</h1>
        <p class="webui-cfg__sub">source: <code>{{ source || '—' }}</code> · revision: <code>{{ revision ?? 0 }}</code></p>
      </div>
      <div class="webui-cfg__buttons">
        <Button outlined icon="pi pi-download" size="small" label="Download" @click="download" />
        <Button outlined icon="pi pi-refresh" size="small" label="Reload" :loading="loading" @click="load" />
      </div>
    </header>

    <Message severity="info" :closable="false">
      M3 dry-run mode: prepare/commit are validated locally; multi-peer two-phase commit lands when etcd wiring is fully active.
    </Message>

    <YamlEditor v-model="yaml" height="60vh" />

    <div class="webui-cfg__actions">
      <Button icon="pi pi-check" size="small" label="Validate" :loading="validating" @click="validate" />
      <Button icon="pi pi-eye" size="small" label="Preview diff" :loading="preparing" @click="preview" />
      <Button v-if="hasPrepared" severity="success" icon="pi pi-cloud-upload" size="small" label="Apply" :loading="committing" @click="apply" />
      <Button v-if="hasPrepared" severity="secondary" outlined icon="pi pi-times" size="small" label="Discard prepared" @click="abort" />
    </div>

    <Message v-if="info" severity="info" :closable="true" @close="info = null">{{ info }}</Message>
    <Message v-if="error" severity="error" :closable="true" @close="error = null">{{ error }}</Message>

    <section v-if="validationIssues.length > 0" class="webui-cfg__issues">
      <h2>Validation issues</h2>
      <ul>
        <li v-for="(it, idx) in validationIssues" :key="idx">
          <code>{{ it.path }}</code>: {{ it.message }}
        </li>
      </ul>
    </section>

    <section v-if="diff.length > 0" class="webui-cfg__diff">
      <h2>Diff ({{ diff.length }} ops)</h2>
      <ul>
        <li v-for="(op, idx) in diff" :key="idx" :class="`webui-cfg__diff-${op.op}`">
          <span class="webui-cfg__diff-tag">{{ op.op }}</span>
          <code>{{ op.path }}</code>
          <span v-if="op.from !== undefined && op.from !== null"> from <code>{{ op.from }}</code></span>
          <span v-if="op.to !== undefined && op.to !== null"> to <code>{{ op.to }}</code></span>
        </li>
      </ul>
    </section>
  </section>
</template>

<style scoped>
.webui-cfg { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-cfg__head { display: flex; justify-content: space-between; align-items: flex-start; }
.webui-cfg__head h1 { margin: 0; }
.webui-cfg__sub { margin: 0.25rem 0 0; color: var(--webui-text-muted); font-size: 0.85rem; }
.webui-cfg__buttons { display: flex; gap: 0.5rem; }
.webui-cfg__editor { font-family: var(--webui-font-mono); font-size: 0.85rem; }
.webui-cfg__actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.webui-cfg__issues, .webui-cfg__diff { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 0.75rem 1rem; }
.webui-cfg__issues h2, .webui-cfg__diff h2 { margin: 0 0 0.5rem; font-size: 1rem; }
.webui-cfg__diff-tag { display: inline-block; min-width: 4.5rem; padding: 0 0.4rem; border-radius: 999px; font-size: 0.7rem; text-transform: uppercase; margin-right: 0.5rem; }
.webui-cfg__diff-added .webui-cfg__diff-tag { background: rgba(60,170,80,0.18); color: #1b7c34; }
.webui-cfg__diff-removed .webui-cfg__diff-tag { background: rgba(220,80,80,0.18); color: #a01a1a; }
.webui-cfg__diff-changed .webui-cfg__diff-tag { background: rgba(220,170,40,0.18); color: #876202; }
</style>
