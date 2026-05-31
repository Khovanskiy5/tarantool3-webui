<script setup lang="ts">
import { onMounted, ref, computed } from 'vue';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';
import { YamlEditor } from '@/widgets/yaml-editor';
import HistoryPanel from './HistoryPanel.vue';
import DiffViewer from './DiffViewer.vue';

interface CurrentCfg { yaml: string; revision: number | null; source: string; }
interface DiffOp { op: string; path: string; from?: string | null; to?: string | null; }
interface PrepareRes {
  prepared_id: string;
  expires_at: number;
  diff: DiffOp[] | null;
  warnings: { path: string; message: string }[] | null;
}
interface CommitRes { revision: number; applied: boolean; message: string | null; }
interface RevisionFull { revision: number; yaml: string; ts: number | null; user: string | null; action: string | null; }

const yaml = ref('');
const source = ref('');
const revision = ref<number | null>(null);
const loading = ref(false);
const validating = ref(false);
const preparing = ref(false);
const committing = ref(false);
const rollingBack = ref(false);
const error = ref<string | null>(null);
const info = ref<string | null>(null);
const validationIssues = ref<{ path: string; message: string }[]>([]);
const preparedId = ref<string | null>(null);
const diff = ref<DiffOp[]>([]);

// History panel ref so the parent can imperatively .refresh() after a
// commit/rollback lands a new entry on the timeline.
const historyPanelRef = ref<InstanceType<typeof HistoryPanel> | null>(null);

// DiffViewer state — driven by HistoryPanel's request-diff event.
const diffViewer = ref({
  open: false,
  title: '',
  originalLabel: '',
  modifiedLabel: '',
  original: '',
  modified: '',
});

const Q_CURRENT = /* GraphQL */ `query Cfg { config { yaml revision source } }`;
const Q_REVISION = /* GraphQL */ `
  query CfgRev($revision: Long!) {
    configRevision(revision: $revision) { revision yaml ts user action }
  }
`;
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
const M_ROLLBACK = /* GraphQL */ `
  mutation Rollback($revision: Long!) {
    rollbackConfig(revision: $revision) { revision applied message }
  }
`;

const load = async () => {
  loading.value = true; error.value = null;
  const res = await getClient().query<{ config: CurrentCfg }>(Q_CURRENT, {}, {
    requestPolicy: 'network-only',
  }).toPromise();
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
  if (res.error) {
    // Backend rejects a no-op submission with the NO_CHANGES error
    // class — render it as a neutral info banner, not a red error.
    // Apply stays disabled because preparedId is still null.
    if (res.error.message.includes('NO_CHANGES')) {
      info.value = 'No changes vs current revision — nothing to commit.';
    } else {
      error.value = res.error.message;
    }
    preparing.value = false;
    return;
  }
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
    historyPanelRef.value?.refresh();
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

// Fetch a historical YAML body via configRevision query. Returns the
// payload on success, surfaces REVISION_NOT_FOUND as a parent banner
// instead of throwing — the timeline can legitimately race the cap
// (worst case: another commit ages out the row between list and read).
const fetchRevisionYaml = async (rev: number): Promise<string | null> => {
  const res = await getClient()
    .query<{ configRevision: RevisionFull }>(Q_REVISION, { revision: rev }, {
      requestPolicy: 'network-only',
    })
    .toPromise();
  if (res.error) {
    // Surface a friendly message for the most common case (aged-out
    // beyond MAX_HISTORY) before bubbling the raw text.
    const msg = res.error.message;
    if (msg.includes('REVISION_NOT_FOUND')) {
      error.value = `Revision #${rev} no longer available — aged out beyond MAX_HISTORY.`;
    } else {
      error.value = msg;
    }
    return null;
  }
  return res.data?.configRevision?.yaml ?? null;
};

const onSelectRevision = async (rev: number) => {
  error.value = null; info.value = null;
  const body = await fetchRevisionYaml(rev);
  if (body == null) return;
  yaml.value = body;
  info.value = `Loaded revision #${rev} into the editor. Review and click "Preview diff" to commit it as the new version.`;
};

const onRequestDiff = async (
  rev: number,
  against: 'prev' | 'current',
) => {
  error.value = null;
  const target = await fetchRevisionYaml(rev);
  if (target == null) return;

  if (against === 'current') {
    diffViewer.value = {
      open: true,
      title: `Diff: revision #${rev} → current (#${revision.value ?? '?'})`,
      originalLabel: `Revision #${rev}`,
      modifiedLabel: `Current (revision #${revision.value ?? '?'})`,
      original: target,
      modified: yaml.value,
    };
    return;
  }

  // "Diff vs prev": find the predecessor on the timeline and pull it.
  // We rely on HistoryPanel having loaded the page already — the prev
  // pointer is recoverable from its own list, but the parent does the
  // fetch to keep the prop surface narrow.
  const prevYaml = await fetchPreviousRevisionYaml(rev);
  if (prevYaml == null) {
    error.value = `Cannot diff #${rev} vs previous — no earlier revision available.`;
    return;
  }
  diffViewer.value = {
    open: true,
    title: `Diff: previous → #${rev}`,
    originalLabel: 'Previous revision',
    modifiedLabel: `Revision #${rev}`,
    original: prevYaml,
    modified: target,
  };
};

const Q_HISTORY_MINIMAL = /* GraphQL */ `
  query CfgHistoryMin { configHistory(limit: 200) { revisions { revision } } }
`;

const fetchPreviousRevisionYaml = async (rev: number): Promise<string | null> => {
  const res = await getClient()
    .query<{ configHistory: { revisions: { revision: number }[] } }>(
      Q_HISTORY_MINIMAL, {}, { requestPolicy: 'network-only' },
    )
    .toPromise();
  if (res.error) { error.value = res.error.message; return null; }
  const list = res.data?.configHistory?.revisions ?? [];
  const sorted = [...list].sort((a, b) => a.revision - b.revision);
  let prev: number | null = null;
  for (const r of sorted) {
    if (r.revision < rev) prev = r.revision;
  }
  if (prev == null) return null;
  return await fetchRevisionYaml(prev);
};

const onRequestRollback = async (rev: number) => {
  // Confirmation guard — rollback is destructive (changes cluster
  // state on every peer). Native confirm() keeps the page free of
  // dialog framework deps; the dedicated DestructiveActionDialog
  // pattern lands in Phase 5 (Task 5.16).
  const ok = window.confirm(
    `Roll the cluster config back to revision #${rev}? ` +
    'This will create a new commit and fan-out config:reload to every peer.',
  );
  if (!ok) return;

  rollingBack.value = true; error.value = null; info.value = null;
  const res = await getClient().mutation<{ rollbackConfig: CommitRes }>(
    M_ROLLBACK, { revision: rev },
  ).toPromise();
  if (res.error) { error.value = res.error.message; rollingBack.value = false; return; }
  const r = res.data?.rollbackConfig;
  if (r?.applied) {
    info.value = r.message ?? `Rolled back to #${rev}. New revision ${r.revision}.`;
    preparedId.value = null;
    diff.value = [];
    await load();
    historyPanelRef.value?.refresh();
  } else {
    error.value = r?.message ?? 'rollback not applied';
  }
  rollingBack.value = false;
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

    <div class="webui-cfg__split">
      <div class="webui-cfg__main">
        <YamlEditor v-model="yaml" height="60vh" />

        <div class="webui-cfg__actions">
          <Button icon="pi pi-check" size="small" label="Validate" :loading="validating" @click="validate" />
          <Button icon="pi pi-eye" size="small" label="Preview diff" :loading="preparing" @click="preview" />
          <Button v-if="hasPrepared" severity="success" icon="pi pi-cloud-upload" size="small" label="Apply" :loading="committing" @click="apply" />
          <Button v-if="hasPrepared" severity="secondary" outlined icon="pi pi-times" size="small" label="Discard prepared" @click="abort" />
        </div>

        <Message v-if="info" severity="info" :closable="true" @close="info = null">{{ info }}</Message>
        <Message v-if="error" severity="error" :closable="true" @close="error = null">{{ error }}</Message>
        <Message v-if="rollingBack" severity="warn" :closable="false">Rolling back to selected revision…</Message>

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
      </div>

      <HistoryPanel
        ref="historyPanelRef"
        :current-revision="revision"
        class="webui-cfg__history"
        @select-revision="onSelectRevision"
        @request-diff="onRequestDiff"
        @request-rollback="onRequestRollback"
      />
    </div>

    <DiffViewer
      :open="diffViewer.open"
      :title="diffViewer.title"
      :original-label="diffViewer.originalLabel"
      :modified-label="diffViewer.modifiedLabel"
      :original="diffViewer.original"
      :modified="diffViewer.modified"
      @close="diffViewer.open = false"
    />
  </section>
</template>

<style scoped>
.webui-cfg { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-cfg__head { display: flex; justify-content: space-between; align-items: flex-start; }
.webui-cfg__head h1 { margin: 0; }
.webui-cfg__sub { margin: 0.25rem 0 0; color: var(--webui-text-muted); font-size: 0.85rem; }
.webui-cfg__buttons { display: flex; gap: 0.5rem; }
.webui-cfg__split {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 320px;
  gap: 1rem;
  align-items: start;
}
.webui-cfg__main {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  min-width: 0;
}
.webui-cfg__history {
  position: sticky;
  top: 1rem;
}
@media (max-width: 1100px) {
  .webui-cfg__split {
    grid-template-columns: 1fr;
  }
  .webui-cfg__history {
    position: static;
    max-height: 50vh;
  }
}
.webui-cfg__editor { font-family: var(--webui-font-mono); font-size: 0.85rem; }
.webui-cfg__actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.webui-cfg__issues, .webui-cfg__diff { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 0.75rem 1rem; }
.webui-cfg__issues h2, .webui-cfg__diff h2 { margin: 0 0 0.5rem; font-size: 1rem; }
.webui-cfg__diff-tag { display: inline-block; min-width: 4.5rem; padding: 0 0.4rem; border-radius: 999px; font-size: 0.7rem; text-transform: uppercase; margin-right: 0.5rem; }
.webui-cfg__diff-added .webui-cfg__diff-tag { background: rgba(60,170,80,0.18); color: #1b7c34; }
.webui-cfg__diff-removed .webui-cfg__diff-tag { background: rgba(220,80,80,0.18); color: #a01a1a; }
.webui-cfg__diff-changed .webui-cfg__diff-tag { background: rgba(220,170,40,0.18); color: #876202; }
</style>
