<!--
  SQL workbench page (Phase 3 Task 3.3).

  Single-pane Monaco SQL editor + Run + per-statement result tabs.
  Multi-statement input is split on `;;` (matches backend); the
  results grid renders one tab per statement so the operator can
  drill in. EXPLAIN runs side-by-side on the same input.

  SEQSCAN auto-retry: if the backend reports
  `seqscan_required: true`, we show a banner offering one-click
  retry with `seqscan_allowed: true` (translates to
  `sql_seq_scan = true` for the duration of the call only).

  Export: per-result-tab CSV / JSON button. CSV escaping handles
  embedded commas, newlines and quotes per RFC 4180.
-->
<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, shallowRef } from 'vue';
import type * as Monaco from 'monaco-editor';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Button from 'primevue/button';
import Message from 'primevue/message';
// PrimeVue 4: TabView/TabPanel deprecated in favor of the new
// Tabs / TabList / Tab / TabPanels / TabPanel composable. The new
// API takes an explicit `value` per Tab and addresses panels by
// the matching `value` instead of relying on slot order.
import Tabs from 'primevue/tabs';
import TabList from 'primevue/tablist';
import Tab from 'primevue/tab';
import TabPanels from 'primevue/tabpanels';
import TabPanel from 'primevue/tabpanel';
import Tag from 'primevue/tag';
import Dialog from 'primevue/dialog';
import InputText from 'primevue/inputtext';
import Checkbox from 'primevue/checkbox';

import { getClient } from '@/shared/api/graphql';
import { useSessionStore } from '@/entities/session';
import { restClient, RestApiError } from '@/shared/api/rest/client';

// ── types matching the backend response ───────────────────────────

interface ColumnMeta { name: string; type: string; }
interface SelectResult {
  metadata: ColumnMeta[];
  rows: unknown[][];
  truncated?: boolean;
}
interface DmlResult { row_count: number; }
interface SqlErrorResult { error: string; seqscan_required?: boolean; }
type StatementResult = SelectResult | DmlResult | SqlErrorResult | { ok: true };

interface SqlResponse {
  statements: StatementResult[];
  latency_ms: number;
  seqscan_required: boolean;
  instance?: string;
}

interface ExplainResponse {
  plans: { statement: string; metadata?: ColumnMeta[]; rows?: unknown[][]; error?: string }[];
  instance?: string;
}

// Saved-query library (Task 3.4).
interface SavedQuery {
  id: number;
  name: string;
  sql: string;
  owner: string;
  created_at: number;
  shared: boolean;
  tags?: string[] | null;
}

// ── state ──────────────────────────────────────────────────────────

const editorContainer = ref<HTMLElement | null>(null);
const monacoEditor = shallowRef<Monaco.editor.IStandaloneCodeEditor | null>(null);
const editorLoading = ref(true);

// Default snippet — identity probe through the `_cluster` system
// view, the SQL equivalent of /console's `return box.info.name,
// box.info.uuid`. An operator switching pages gets the same kind
// of "is this the right peer?" answer in either dialect.
const initialSql = `-- Workbench / SQL\n--\n-- Run with Cmd+Enter or the Run button. Separate statements\n-- with \`;;\` (double semicolon). Single \`;\` stays inside the\n-- statement as a literal.\n\nSELECT "name", "uuid" FROM "_cluster";;\n`;
const currentSql = ref(initialSql);
const result = ref<SqlResponse | null>(null);
const explain = ref<ExplainResponse | null>(null);
const latency = ref<number | null>(null);
const error = ref<string | null>(null);
const running = ref(false);
const explainRunning = ref(false);
const seqscanRequired = ref(false);
// PrimeVue 4 Tabs addresses panels by `value` (string-or-number).
// We use the statement index converted to string so it matches the
// `:value="idx"` binding on each Tab without TS friction.
const activeTab = ref<string | number>(0);

const session = useSessionStore();
const savedQueries = ref<SavedQuery[]>([]);
const savedQueriesLoading = ref(false);
const saveDialogOpen = ref(false);
const saveName = ref('');
const saveShared = ref(false);
const savingNow = ref(false);

// Built-in cookbook — non-deletable curated snippets the operator
// can drop into the editor with one click. Kept outside the saved
// space because a fresh install should not need a write to be
// useful, and these are dialect-stable across deployments.
const BUILTIN_SNIPPETS: { name: string; sql: string }[] = [
  { name: 'cluster identity', sql: 'SELECT "name", "uuid" FROM "_cluster"' },
  { name: 'spaces overview',  sql: 'SELECT id, name, engine FROM "_vspace" WHERE name NOT LIKE \'\\_%\' ESCAPE \'\\\'' },
  { name: 'index list',       sql: 'SELECT id, name, type FROM "_vindex" LIMIT 50' },
  { name: 'users + roles',    sql: 'SELECT id, name, type FROM "_vuser"' },
  { name: 'session settings', sql: 'SELECT name, value FROM "_session_settings"' },
];

// ── Monaco bootstrap (shared bundle with config-editor) ───────────

const initMonacoEnv = async () => {
  const EditorWorker = (await import(
    'monaco-editor/esm/vs/editor/editor.worker?worker'
  )).default;
  (self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
  };
};

const mountEditor = async () => {
  if (editorContainer.value == null) return;
  editorLoading.value = true;
  await initMonacoEnv();
  const monaco = await import('monaco-editor');
  await import('monaco-editor/esm/vs/basic-languages/sql/sql.contribution');

  monacoEditor.value = monaco.editor.create(editorContainer.value, {
    value: currentSql.value,
    language: 'sql',
    automaticLayout: true,
    minimap: { enabled: false },
    fontSize: 13,
    fontFamily: 'var(--webui-font-mono, "JetBrains Mono", monospace)',
    scrollBeyondLastLine: false,
    theme: document.body.classList.contains('webui-dark') ? 'vs-dark' : 'vs',
    lineNumbers: 'on',
  });

  monacoEditor.value.onDidChangeModelContent(() => {
    currentSql.value = monacoEditor.value!.getValue();
  });

  monacoEditor.value.addCommand(
    monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter,
    () => { void runQuery(); },
  );

  editorLoading.value = false;
};

const disposeEditor = () => {
  monacoEditor.value?.dispose();
  monacoEditor.value = null;
};

// Mount once the container is in the DOM.
const initialMount = async () => {
  await nextTick();
  await mountEditor();
};
void initialMount();
onBeforeUnmount(disposeEditor);

// ── API calls ─────────────────────────────────────────────────────

// restClient owns CSRF cookie ↔ header coupling (`webui_csrf`
// cookie → `x-csrf-token` header) plus 401 redirect. Hand-rolled
// fetch on the page would read the wrong cookie name and every
// call dies with `csrf token missing or invalid`.

async function runQuery(opts: { seqscanAllowed?: boolean } = {}) {
  if (running.value) return;
  running.value = true;
  error.value = null;
  seqscanRequired.value = false;
  try {
    const body = await restClient.post<SqlResponse>('/api/sql', {
      statement: currentSql.value,
      seqscan_allowed: opts.seqscanAllowed === true,
    });
    result.value = body;
    latency.value = body.latency_ms ?? null;
    seqscanRequired.value = body.seqscan_required === true;
    activeTab.value = 0;
  } catch (e) {
    if (e instanceof RestApiError) {
      error.value = `${e.code}: ${e.message}`;
    } else {
      error.value = (e as Error).message;
    }
    result.value = null;
    latency.value = null;
  } finally {
    running.value = false;
  }
}

// ── saved queries ──────────────────────────────────────────────────

const SAVED_Q_QUERY = /* GraphQL */ `
  query SqlSavedQueries {
    savedQueries { items { id name sql owner created_at shared tags } }
  }
`;
const SAVED_Q_SAVE_M = /* GraphQL */ `
  mutation SqlSaveQuery($name: String!, $sql: String!, $shared: Boolean) {
    saveQuery(name: $name, sql: $sql, shared: $shared) {
      ok item { id name sql owner created_at shared }
    }
  }
`;
const SAVED_Q_DELETE_M = /* GraphQL */ `
  mutation SqlDeleteSavedQuery($id: Long!) {
    deleteSavedQuery(id: $id) { ok item { id name owner } }
  }
`;

async function loadSavedQueries() {
  savedQueriesLoading.value = true;
  const res = await getClient()
    .query<{ savedQueries: { items: SavedQuery[] } }>(
      SAVED_Q_QUERY, {}, { requestPolicy: 'network-only' })
    .toPromise();
  savedQueriesLoading.value = false;
  if (res.error) return;
  savedQueries.value = res.data?.savedQueries?.items ?? [];
}

function openSaveDialog() {
  saveName.value = '';
  saveShared.value = false;
  saveDialogOpen.value = true;
}

async function saveCurrentQuery() {
  if (!saveName.value.trim() || !currentSql.value.trim()) return;
  savingNow.value = true;
  const res = await getClient()
    .mutation(SAVED_Q_SAVE_M, {
      name: saveName.value.trim(),
      sql: currentSql.value,
      shared: saveShared.value,
    })
    .toPromise();
  savingNow.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  saveDialogOpen.value = false;
  await loadSavedQueries();
}

async function deleteSnippet(s: SavedQuery) {
  if (!window.confirm(`Delete saved query "${s.name}"?`)) return;
  const res = await getClient()
    .mutation(SAVED_Q_DELETE_M, { id: s.id })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  await loadSavedQueries();
}

function loadIntoEditor(sql: string) {
  currentSql.value = sql;
  monacoEditor.value?.setValue(sql);
}

const currentUser = () => session.user ?? '';

onMounted(() => {
  void loadSavedQueries();
});

async function runExplain() {
  if (explainRunning.value) return;
  explainRunning.value = true;
  try {
    explain.value = await restClient.post<ExplainResponse>(
      '/api/sql/explain', { statement: currentSql.value });
  } catch (e) {
    if (e instanceof RestApiError) error.value = `${e.code}: ${e.message}`;
    else error.value = (e as Error).message;
    explain.value = null;
  } finally {
    explainRunning.value = false;
  }
}

// ── export helpers ─────────────────────────────────────────────────

function csvEscape(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  if (s.includes(',') || s.includes('"') || s.includes('\n')) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

function downloadBlob(filename: string, contents: string, mime: string) {
  const blob = new Blob([contents], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function exportCsv(stmt: SelectResult, idx: number) {
  const cols = stmt.metadata.map((m) => m.name);
  const lines = [cols.map(csvEscape).join(',')];
  for (const row of stmt.rows) {
    lines.push(row.map(csvEscape).join(','));
  }
  downloadBlob(`sql-result-${idx + 1}.csv`, lines.join('\n'), 'text/csv');
}

function exportJson(stmt: SelectResult, idx: number) {
  const cols = stmt.metadata.map((m) => m.name);
  const out = stmt.rows.map((r) => Object.fromEntries(cols.map((c, i) => [c, r[i]])));
  downloadBlob(`sql-result-${idx + 1}.json`, JSON.stringify(out, null, 2), 'application/json');
}

// ── per-statement helpers ─────────────────────────────────────────

function isSelect(r: StatementResult): r is SelectResult {
  return (r as SelectResult).metadata !== undefined
    && (r as SelectResult).rows !== undefined;
}

function isDml(r: StatementResult): r is DmlResult {
  return (r as DmlResult).row_count !== undefined;
}

function isError(r: StatementResult): r is SqlErrorResult {
  return (r as SqlErrorResult).error !== undefined;
}

function statementTabLabel(r: StatementResult, idx: number): string {
  if (isError(r)) return `#${idx + 1} — error`;
  if (isSelect(r)) return `#${idx + 1} — ${r.rows.length} row${r.rows.length === 1 ? '' : 's'}`;
  if (isDml(r)) return `#${idx + 1} — ${r.row_count} affected`;
  return `#${idx + 1}`;
}

function renderCell(v: unknown): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
</script>

<template>
  <section class="webui-sql">
    <aside class="webui-sql__sidebar">
      <header class="webui-sql__sidebar-head">
        <h2>Library</h2>
        <Button
          icon="pi pi-save"
          severity="success"
          text
          size="small"
          aria-label="Save current query"
          @click="openSaveDialog"
        />
      </header>
      <section class="webui-sql__section">
        <header class="webui-sql__section-head">
          <strong>Mine</strong>
        </header>
        <ul class="webui-sql__list">
          <li
            v-for="s in savedQueries.filter((q) => q.owner === currentUser() && !q.shared)"
            :key="s.id"
            class="webui-sql__list-item"
          >
            <span class="webui-sql__list-name" @click="loadIntoEditor(s.sql)">{{ s.name }}</span>
            <Button
              icon="pi pi-trash"
              text
              severity="danger"
              size="small"
              aria-label="Delete snippet"
              @click="deleteSnippet(s)"
            />
          </li>
          <li v-if="!savedQueriesLoading && savedQueries.filter((q) => q.owner === currentUser() && !q.shared).length === 0" class="webui-sql__muted">
            No private snippets.
          </li>
        </ul>
      </section>
      <section class="webui-sql__section">
        <header class="webui-sql__section-head">
          <strong>Shared</strong>
        </header>
        <ul class="webui-sql__list">
          <li
            v-for="s in savedQueries.filter((q) => q.shared)"
            :key="s.id"
            class="webui-sql__list-item"
          >
            <span class="webui-sql__list-name" @click="loadIntoEditor(s.sql)">
              {{ s.name }}
              <small class="webui-sql__list-owner">@{{ s.owner }}</small>
            </span>
            <Button
              v-if="s.owner === currentUser()"
              icon="pi pi-trash"
              text
              severity="danger"
              size="small"
              aria-label="Delete shared snippet"
              @click="deleteSnippet(s)"
            />
          </li>
          <li v-if="!savedQueriesLoading && savedQueries.filter((q) => q.shared).length === 0" class="webui-sql__muted">
            No shared snippets.
          </li>
        </ul>
      </section>
      <section class="webui-sql__section">
        <header class="webui-sql__section-head">
          <strong>Built-in</strong>
        </header>
        <ul class="webui-sql__list">
          <li
            v-for="b in BUILTIN_SNIPPETS"
            :key="b.name"
            class="webui-sql__list-item"
          >
            <span class="webui-sql__list-name" @click="loadIntoEditor(b.sql)">{{ b.name }}</span>
          </li>
        </ul>
      </section>
    </aside>

    <div class="webui-sql__main">
    <header class="webui-sql__head">
      <h1>SQL</h1>
      <div class="webui-sql__actions">
        <Button
          label="Run"
          icon="pi pi-play"
          severity="success"
          size="small"
          :loading="running"
          @click="runQuery()"
        />
        <Button
          label="EXPLAIN"
          icon="pi pi-sitemap"
          severity="info"
          size="small"
          text
          :loading="explainRunning"
          @click="runExplain"
        />
        <Button
          label="Save"
          icon="pi pi-bookmark"
          severity="secondary"
          size="small"
          text
          @click="openSaveDialog"
        />
        <span v-if="latency !== null" class="webui-sql__latency">
          {{ latency.toFixed(1) }} ms
        </span>
      </div>
    </header>

    <div class="webui-sql__editor-wrap">
      <div ref="editorContainer" class="webui-sql__editor" />
      <p v-if="editorLoading" class="webui-sql__muted">Loading editor…</p>
    </div>

    <Message
      v-if="seqscanRequired"
      severity="warn"
      :closable="false"
      class="webui-sql__banner"
    >
      <strong>Sequence scan required.</strong>
      Tarantool blocks full-scan SELECTs by default
      (<code>sql_seq_scan = false</code>). Re-run with the toggle
      enabled for this call only — the session setting is restored
      after the response.
      <Button
        label="Re-run with SEQSCAN"
        icon="pi pi-refresh"
        size="small"
        severity="warn"
        @click="runQuery({ seqscanAllowed: true })"
      />
    </Message>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <Tabs v-if="result" v-model:value="activeTab" class="webui-sql__tabs">
      <TabList>
        <Tab v-for="(stmt, idx) in result.statements" :key="idx" :value="idx">
          {{ statementTabLabel(stmt, idx) }}
        </Tab>
      </TabList>
      <TabPanels>
      <TabPanel
        v-for="(stmt, idx) in result.statements"
        :key="idx"
        :value="idx"
      >
        <div v-if="isError(stmt)" class="webui-sql__err">
          <Message severity="error" :closable="false">{{ stmt.error }}</Message>
        </div>
        <div v-else-if="isSelect(stmt)" class="webui-sql__select">
          <div class="webui-sql__select-tools">
            <Tag
              v-if="stmt.truncated"
              value="truncated"
              severity="warn"
              class="webui-sql__chip"
            />
            <Button
              label="CSV"
              icon="pi pi-download"
              text
              size="small"
              @click="exportCsv(stmt, idx)"
            />
            <Button
              label="JSON"
              icon="pi pi-download"
              text
              size="small"
              @click="exportJson(stmt, idx)"
            />
          </div>
          <DataTable
            :value="stmt.rows.map((r) => Object.fromEntries(stmt.metadata.map((m, i) => [m.name, r[i]])))"
            size="small"
            striped-rows
            scrollable
            scroll-height="400px"
            :row-hover="true"
            class="webui-sql__grid"
          >
            <Column
              v-for="m in stmt.metadata"
              :key="m.name"
              :field="m.name"
              :header="`${m.name} (${m.type})`"
            >
              <template #body="{ data }">
                <span :class="{ 'webui-sql__null': (data[m.name] ?? null) === null }">
                  {{ renderCell(data[m.name]) }}
                </span>
              </template>
            </Column>
            <template #empty>
              <span class="webui-sql__muted">No rows.</span>
            </template>
          </DataTable>
        </div>
        <div v-else-if="isDml(stmt)" class="webui-sql__dml">
          <strong>{{ stmt.row_count }}</strong> row(s) affected.
        </div>
        <div v-else class="webui-sql__muted">OK.</div>
      </TabPanel>
      </TabPanels>
    </Tabs>

    <section v-if="explain" class="webui-sql__plans">
      <h2>EXPLAIN QUERY PLAN</h2>
      <div v-for="(p, idx) in explain.plans" :key="idx" class="webui-sql__plan">
        <header>
          <code>{{ p.statement }}</code>
        </header>
        <Message v-if="p.error" severity="error" :closable="false">{{ p.error }}</Message>
        <DataTable
          v-else
          :value="(p.rows ?? []).map((r) => Object.fromEntries((p.metadata ?? []).map((m, i) => [m.name, r[i]])))"
          size="small"
          striped-rows
        >
          <Column
            v-for="m in p.metadata ?? []"
            :key="m.name"
            :field="m.name"
            :header="m.name"
          />
        </DataTable>
      </div>
    </section>

    </div>

    <Dialog
      v-model:visible="saveDialogOpen"
      modal
      header="Save SQL snippet"
      :style="{ width: '32rem' }"
    >
      <div class="webui-sql__save-row">
        <label>Name</label>
        <InputText v-model="saveName" placeholder="my query" />
      </div>
      <div class="webui-sql__save-row">
        <label>Share</label>
        <label class="webui-sql__inline">
          <Checkbox v-model="saveShared" binary />
          <span>Visible to every operator+</span>
        </label>
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="saveDialogOpen = false" />
        <Button
          label="Save"
          icon="pi pi-save"
          severity="success"
          :loading="savingNow"
          :disabled="!saveName.trim() || !currentSql.trim()"
          @click="saveCurrentQuery"
        />
      </template>
    </Dialog>

  </section>
</template>

<style scoped>
.webui-sql {
  display: grid;
  grid-template-columns: 260px 1fr;
  height: 100%;
  min-height: calc(100vh - 4rem);
}
.webui-sql__sidebar {
  border-right: 1px solid var(--webui-border);
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  overflow-y: auto;
}
.webui-sql__sidebar-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.webui-sql__sidebar-head h2 { margin: 0; font-size: 1rem; }
.webui-sql__section { display: flex; flex-direction: column; gap: 0.25rem; }
.webui-sql__section-head { color: var(--webui-text-muted); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }
.webui-sql__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0.1rem; }
.webui-sql__list-item {
  display: flex; justify-content: space-between; align-items: center;
  padding: 0.3rem 0.4rem; border-radius: var(--webui-radius);
  font-size: 0.85rem;
}
.webui-sql__list-item:hover { background: var(--p-content-hover-background, rgba(255,255,255,0.04)); }
.webui-sql__list-name { cursor: pointer; flex: 1 1 auto; }
.webui-sql__list-owner { color: var(--webui-text-muted); font-size: 0.7rem; margin-left: 0.3rem; }
.webui-sql__main {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  overflow: hidden;
}
.webui-sql__save-row { display: grid; grid-template-columns: 6rem 1fr; gap: 0.5rem; align-items: center; margin-bottom: 0.5rem; }
.webui-sql__save-row label { color: var(--webui-text-muted); font-size: 0.85rem; }
.webui-sql__inline { display: inline-flex; align-items: center; gap: 0.4rem; }
.webui-sql__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.webui-sql__head h1 { margin: 0; }
.webui-sql__actions {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
}
.webui-sql__latency {
  color: var(--webui-text-muted);
  font-size: 0.8rem;
  font-family: var(--webui-font-mono);
  padding-left: 0.5rem;
  border-left: 1px solid var(--webui-border);
  margin-left: 0.25rem;
}
/* New PrimeVue 4 Tabs uses its own --p-tabs-* token family; the
 * Aura dark scheme leaves those at light defaults, so without a
 * bridge the active tab gets a white underline and a bright text
 * row on top of our dark page. Alias the family here. */
.webui-sql__tabs :deep(.p-tabs-tablist) {
  background: transparent;
  border-bottom: 1px solid var(--p-content-border-color);
}
.webui-sql__tabs :deep(.p-tab) {
  color: var(--p-text-muted-color);
  background: transparent;
}
.webui-sql__tabs :deep(.p-tab:hover) {
  color: var(--p-text-color);
}
.webui-sql__tabs :deep(.p-tab[data-p-active="true"]) {
  color: var(--p-highlight-color);
  border-color: var(--p-highlight-background);
}
.webui-sql__tabs :deep(.p-tabpanels) {
  background: transparent;
  padding: 0.75rem 0;
}
.webui-sql__editor-wrap {
  position: relative;
  height: 16rem;
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  overflow: hidden;
}
.webui-sql__editor {
  width: 100%;
  height: 100%;
}
.webui-sql__banner :deep(.p-message-text) {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-sql__tabs :deep(.p-tabview-nav) {
  background: transparent;
  border-bottom: 1px solid var(--webui-border);
}
.webui-sql__select-tools {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 0.5rem;
}
.webui-sql__dml { font-size: 0.95rem; padding: 0.5rem; }
.webui-sql__plans {
  border-top: 1px solid var(--webui-border);
  padding-top: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.webui-sql__plan header { margin-bottom: 0.3rem; }
.webui-sql__plan code { color: var(--webui-text-muted); font-size: 0.8rem; }
.webui-sql__muted { color: var(--webui-text-muted); }
.webui-sql__null { color: var(--webui-text-muted); font-style: italic; }
.webui-sql__chip { font-size: 0.65rem; }
</style>
