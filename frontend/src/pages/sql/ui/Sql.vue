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
import { nextTick, onBeforeUnmount, ref, shallowRef } from 'vue';
import type * as Monaco from 'monaco-editor';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Button from 'primevue/button';
import Message from 'primevue/message';
import TabView from 'primevue/tabview';
import TabPanel from 'primevue/tabpanel';
import Tag from 'primevue/tag';

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
const activeTab = ref(0);

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

const xhrJson = async (path: string, payload: unknown) => {
  const csrf = document.cookie
    .split('; ')
    .find((c) => c.startsWith('csrf_token='))
    ?.split('=')[1] ?? '';
  const res = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': csrf,
    },
    body: JSON.stringify(payload),
  });
  return { status: res.status, body: await res.json() };
};

async function runQuery(opts: { seqscanAllowed?: boolean } = {}) {
  if (running.value) return;
  running.value = true;
  error.value = null;
  seqscanRequired.value = false;
  try {
    const { status, body } = await xhrJson('/api/sql', {
      statement: currentSql.value,
      seqscan_allowed: opts.seqscanAllowed === true,
    });
    if (status !== 200) {
      error.value = body?.error?.message ?? `HTTP ${status}`;
      result.value = null;
      latency.value = null;
      return;
    }
    result.value = body as SqlResponse;
    latency.value = body.latency_ms ?? null;
    seqscanRequired.value = body.seqscan_required === true;
    activeTab.value = 0;
  } catch (e) {
    error.value = String(e);
  } finally {
    running.value = false;
  }
}

async function runExplain() {
  if (explainRunning.value) return;
  explainRunning.value = true;
  try {
    const { status, body } = await xhrJson('/api/sql/explain', {
      statement: currentSql.value,
    });
    if (status !== 200) {
      explain.value = null;
      return;
    }
    explain.value = body as ExplainResponse;
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

    <TabView v-if="result" v-model:active-index="activeTab" class="webui-sql__tabs">
      <TabPanel
        v-for="(stmt, idx) in result.statements"
        :key="idx"
        :value="idx"
        :header="statementTabLabel(stmt, idx)"
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
    </TabView>

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
  </section>
</template>

<style scoped>
.webui-sql {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  height: 100%;
  min-height: calc(100vh - 4rem);
}
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
