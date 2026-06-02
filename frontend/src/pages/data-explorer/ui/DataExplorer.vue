<!--
  /data-explorer — phpMyAdmin-style tuple browser.

  Two-pane layout: sidebar lists every space (user/system toggle,
  sync-badge), main pane shows the selected space's tuples with
  cursor-based pagination, AND-combined filter chips, and CRUD
  buttons that open a TupleForm modal.

  All GraphQL calls go through the shared urql client; the backend
  enforces RBAC + the sensitive-space deny-list, so the UI is free
  to display the edit affordances on every row and let the server
  decide.
-->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import ToggleSwitch from 'primevue/toggleswitch';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Select from 'primevue/select';
import InputText from 'primevue/inputtext';
import Message from 'primevue/message';
import Chip from 'primevue/chip';

import { getClient } from '@/shared/api/graphql';
import TupleForm from './TupleForm.vue';
import SpaceForm from './SpaceForm.vue';

// ── types mirroring the backend GraphQL schema ─────────────────────

interface FieldFormat {
  name: string;
  type: string;
  is_nullable: boolean | null;
  collation: string | null;
}

interface IndexInfo {
  id: number;
  name: string;
  type: string | null;
  unique: boolean | null;
  parts: string[] | null;
}

interface SpaceInfo {
  id: number;
  name: string;
  engine: string | null;
  row_count: number | null;
  size_bytes: number | null;
  is_sync: boolean | null;
  triggers_count: number | null;
  sequence: string | null;
  format: FieldFormat[] | null;
  indexes: IndexInfo[] | null;
}

// Binary envelope shape returned by the resolver for non-UTF-8
// fields. We render these as a compact `[binary N bytes]` chip
// rather than dumping the base64 blob inline.
type FieldValue = unknown | { _binary_base64: string };

interface TupleRow {
  fields: FieldValue[];
  pk_string: string;
}

interface TupleConnection {
  items: TupleRow[];
  next_cursor: string | null;
  total: number | null;
  partial_scan: boolean;
  truncated: boolean;
  index_used: string | null;
}

type FilterOp = 'EQ' | 'NE' | 'GT' | 'GE' | 'LT' | 'LE' | 'LIKE' | 'PREFIX';

interface FilterChip {
  field: string;
  op: FilterOp;
  value: string;
}

// ── GraphQL operations (inline; mirrors the existing pattern) ──────

const SPACES_Q = /* GraphQL */ `
  query DxSpaces($sys: Boolean!) {
    spaces(include_system: $sys) {
      spaces {
        id
        name
        engine
        row_count
        size_bytes
        is_sync
        triggers_count
        sequence
        format {
          name
          type
          is_nullable
          collation
        }
        indexes {
          id
          name
          type
          unique
          parts
        }
      }
    }
  }
`;

const TUPLES_Q = /* GraphQL */ `
  query DxTuples(
    $space: String!
    $filter: [TupleFilterInput!]
    $index: String
    $limit: Int
    $after: String
    $allow_full_scan: Boolean
  ) {
    tuples(
      space: $space
      filter: $filter
      index: $index
      limit: $limit
      after: $after
      allow_full_scan: $allow_full_scan
    ) {
      items {
        fields
        pk_string
      }
      next_cursor
      total
      partial_scan
      truncated
      index_used
    }
  }
`;

const DELETE_M = /* GraphQL */ `
  mutation DxDelete($space: String!, $key: [Json!]!) {
    tupleDelete(space: $space, key: $key) {
      ok
      before
    }
  }
`;

const DROP_SPACE_M = /* GraphQL */ `
  mutation DxDropSpace($name: String!) {
    dropSpace(name: $name) {
      ok
      name
      forwarded
      leader
    }
  }
`;

// ── state ───────────────────────────────────────────────────────────

const spaces = ref<SpaceInfo[]>([]);
const selectedSpace = ref<SpaceInfo | null>(null);
const includeSystem = ref(false);
const sidebarFilter = ref('');
const loadingSpaces = ref(false);
const error = ref<string | null>(null);

const tuples = ref<TupleRow[]>([]);
const cursorStack = ref<string[]>([]);
const currentCursor = ref<string | null>(null);
const nextCursor = ref<string | null>(null);
const totalRows = ref<number | null>(null);
const partialScan = ref(false);
const truncated = ref(false);
const indexUsed = ref<string | null>(null);
const loadingTuples = ref(false);
const allowFullScan = ref(false);
const pageSize = ref<number>(50);

const filterChips = ref<FilterChip[]>([]);
const newFilterField = ref<string>('');
const newFilterOp = ref<FilterOp>('EQ');
const newFilterValue = ref<string>('');

const tupleFormOpen = ref(false);
const tupleFormMode = ref<'create' | 'edit'>('create');
const tupleFormInitial = ref<FieldValue[] | null>(null);

const spaceFormOpen = ref(false);
const spaceFormMode = ref<'create' | 'alter'>('create');
const spaceFormSource = ref<SpaceInfo | null>(null);

// Identity: the Sign-out chip already shows the connected instance,
// but the follower banner explains the forward-to-leader path so
// operators understand why a delete might land on a different box.
const selfInstance = ref<string | null>(null);
const selfRo = ref<boolean | null>(null);

// ── loaders ────────────────────────────────────────────────────────

async function loadSpaces() {
  loadingSpaces.value = true;
  error.value = null;
  const res = await getClient()
    .query<{
      spaces: { spaces: SpaceInfo[] };
    }>(SPACES_Q, { sys: includeSystem.value }, { requestPolicy: 'network-only' })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loadingSpaces.value = false;
    return;
  }
  spaces.value = res.data?.spaces?.spaces ?? [];
  loadingSpaces.value = false;
  // Pick the first user space by default if nothing selected yet.
  if (selectedSpace.value === null && spaces.value.length > 0) {
    const firstUser = spaces.value.find((s) => !s.name.startsWith('_'));
    selectSpace(firstUser ?? spaces.value[0]);
  }
}

async function loadSelfIdentity() {
  try {
    const res = await fetch('/api/health', { credentials: 'same-origin' });
    if (!res.ok) return;
    const body = await res.json();
    selfInstance.value = body.instance ?? null;
    // /api/health does not currently expose box.info.ro; the
    // forward-to-leader path on the backend is what handles
    // the routing — we just show the connected instance for
    // operator orientation. selfRo stays null on purpose.
    selfRo.value = null;
  } catch {
    /* health failures are surfaced by the existing health badge */
  }
}

function selectSpace(s: SpaceInfo) {
  selectedSpace.value = s;
  cursorStack.value = [];
  currentCursor.value = null;
  filterChips.value = [];
  allowFullScan.value = false;
  newFilterField.value = s.format?.[0]?.name ?? '';
  loadTuples();
}

async function loadTuples() {
  if (selectedSpace.value === null) return;
  loadingTuples.value = true;
  error.value = null;
  const res = await getClient()
    .query<{ tuples: TupleConnection }>(
      TUPLES_Q,
      {
        space: selectedSpace.value.name,
        filter:
          filterChips.value.length > 0
            ? filterChips.value.map((c) => ({
                field: c.field,
                // graphql-server validates enum variables against
                // `value`, not `name` — sending the UPPER enum name
                // crashes the request before it reaches the resolver
                // ("Wrong variable filter[i].op for the Enum FilterOp").
                // The schema's value mapping is identity-lowercase
                // (EQ → 'eq', LIKE → 'like'), so the cast is safe.
                op: c.op.toLowerCase(),
                value: coerceFilterValue(c, selectedSpace.value!),
              }))
            : null,
        limit: pageSize.value,
        after: currentCursor.value,
        allow_full_scan: allowFullScan.value,
      },
      { requestPolicy: 'network-only' },
    )
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loadingTuples.value = false;
    return;
  }
  const conn = res.data?.tuples;
  if (conn) {
    tuples.value = conn.items;
    nextCursor.value = conn.next_cursor;
    totalRows.value = conn.total;
    partialScan.value = conn.partial_scan;
    truncated.value = conn.truncated;
    indexUsed.value = conn.index_used;
  }
  loadingTuples.value = false;
}

// SPA wire format: chip.value is a plain string. The backend's Json
// scalar accepts anything; we attempt a JSON.parse for numbers /
// booleans / objects so the operator can type `42` instead of
// `"42"`. Anything that fails to parse is passed as a raw string,
// which is the right call for textual fields.
function coerceFilterValue(c: FilterChip, sp: SpaceInfo): unknown {
  const fmt = sp.format?.find((f) => f.name === c.field);
  const t = fmt?.type ?? 'any';
  if (t === 'unsigned' || t === 'integer' || t === 'number') {
    const n = Number(c.value);
    return Number.isFinite(n) ? n : c.value;
  }
  if (t === 'boolean') return c.value === 'true';
  try {
    if (
      (c.value.startsWith('{') && c.value.endsWith('}')) ||
      (c.value.startsWith('[') && c.value.endsWith(']'))
    ) {
      return JSON.parse(c.value);
    }
  } catch {
    /* fall through */
  }
  return c.value;
}

function addFilterChip() {
  if (!newFilterField.value) return;
  filterChips.value.push({
    field: newFilterField.value,
    op: newFilterOp.value,
    value: newFilterValue.value,
  });
  newFilterValue.value = '';
  cursorStack.value = [];
  currentCursor.value = null;
  loadTuples();
}

function removeFilterChip(idx: number) {
  filterChips.value.splice(idx, 1);
  cursorStack.value = [];
  currentCursor.value = null;
  loadTuples();
}

function nextPage() {
  if (nextCursor.value === null) return;
  cursorStack.value.push(currentCursor.value ?? '');
  currentCursor.value = nextCursor.value;
  loadTuples();
}

function prevPage() {
  if (cursorStack.value.length === 0) return;
  currentCursor.value = cursorStack.value.pop() || null;
  loadTuples();
}

// ── tuple actions ──────────────────────────────────────────────────

function openCreate() {
  tupleFormMode.value = 'create';
  tupleFormInitial.value = null;
  tupleFormOpen.value = true;
}

function openEdit(row: TupleRow) {
  tupleFormMode.value = 'edit';
  tupleFormInitial.value = row.fields;
  tupleFormOpen.value = true;
}

async function deleteRow(row: TupleRow) {
  if (selectedSpace.value === null) return;
  const fmt = selectedSpace.value.format ?? [];
  const pkParts = selectedSpace.value.indexes?.find((i) => i.id === 0)?.parts ?? [];
  const key = pkParts.map((partName) => {
    const fno = fmt.findIndex((f) => f.name === partName);
    return fno >= 0 ? row.fields[fno] : null;
  });
  const confirmed = window.confirm(
    `Delete tuple ${row.pk_string} from ${selectedSpace.value.name}?`,
  );
  if (!confirmed) return;
  const res = await getClient()
    .mutation(DELETE_M, { space: selectedSpace.value.name, key })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  loadTuples();
}

function onTupleFormSaved() {
  tupleFormOpen.value = false;
  loadTuples();
}

function openCreateSpace() {
  spaceFormMode.value = 'create';
  spaceFormSource.value = null;
  spaceFormOpen.value = true;
}

function openAlterSpace(s: SpaceInfo) {
  spaceFormMode.value = 'alter';
  spaceFormSource.value = s;
  spaceFormOpen.value = true;
}

async function onSpaceFormSaved() {
  spaceFormOpen.value = false;
  await loadSpaces();
}

async function dropSpace(s: SpaceInfo) {
  if (s.name.startsWith('_')) return;
  const confirmed = window.prompt(`Drop space "${s.name}"? Type the name to confirm:`);
  if (confirmed !== s.name) return;
  const res = await getClient().mutation(DROP_SPACE_M, { name: s.name }).toPromise();
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  if (selectedSpace.value?.id === s.id) {
    selectedSpace.value = null;
    tuples.value = [];
  }
  await loadSpaces();
}

// ── presentation helpers ──────────────────────────────────────────

function renderField(v: FieldValue): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'object' && '_binary_base64' in (v as object)) {
    const b = (v as { _binary_base64: string })._binary_base64;
    // base64 length × 3/4 ≈ bytes
    const bytes = Math.ceil((b.length * 3) / 4);
    return `[binary ${bytes}B]`;
  }
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function humanBytes(n: number | null): string {
  if (n === null || n === undefined) return '—';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

const filteredSidebarSpaces = computed(() => {
  const q = sidebarFilter.value.trim().toLowerCase();
  if (!q) return spaces.value;
  return spaces.value.filter((s) => s.name.toLowerCase().includes(q));
});

const fieldOptions = computed(() =>
  (selectedSpace.value?.format ?? []).map((f) => ({
    label: `${f.name} (${f.type})`,
    value: f.name,
  })),
);

const PAGE_SIZE_OPTIONS: { label: string; value: number }[] = [
  { label: '25', value: 25 },
  { label: '50', value: 50 },
  { label: '100', value: 100 },
  { label: '500', value: 500 },
];

const OP_OPTIONS: { label: string; value: FilterOp }[] = [
  { label: '=', value: 'EQ' },
  { label: '≠', value: 'NE' },
  { label: '>', value: 'GT' },
  { label: '≥', value: 'GE' },
  { label: '<', value: 'LT' },
  { label: '≤', value: 'LE' },
  { label: 'LIKE', value: 'LIKE' },
  { label: 'prefix', value: 'PREFIX' },
];

onMounted(() => {
  loadSpaces();
  loadSelfIdentity();
});

watch(includeSystem, () => {
  selectedSpace.value = null;
  loadSpaces();
});
</script>

<template>
  <section class="webui-dx">
    <!-- Sidebar -->
    <aside class="webui-dx__sidebar">
      <header class="webui-dx__sidebar-head">
        <h2>Spaces</h2>
        <span class="webui-dx__sidebar-tools">
          <Button
            icon="pi pi-plus"
            severity="success"
            text
            size="small"
            aria-label="New space"
            @click="openCreateSpace"
          />
          <label class="webui-dx__toggle">
            <ToggleSwitch v-model="includeSystem" />
            <span>System</span>
          </label>
        </span>
      </header>
      <InputText
        v-model="sidebarFilter"
        placeholder="filter…"
        size="small"
        class="webui-dx__sidebar-filter"
      />
      <ul v-if="!loadingSpaces" class="webui-dx__list">
        <li
          v-for="s in filteredSidebarSpaces"
          :key="s.id"
          class="webui-dx__list-item"
          :class="{
            'is-selected': selectedSpace?.id === s.id,
            'is-system': s.name.startsWith('_'),
          }"
          @click="selectSpace(s)"
        >
          <span class="webui-dx__list-name">{{ s.name }}</span>
          <span class="webui-dx__list-meta">
            <Tag
              :value="s.is_sync ? 'sync' : 'async'"
              :severity="s.is_sync ? 'success' : 'secondary'"
              class="webui-dx__sync-badge"
            />
            <span class="webui-dx__list-count">{{ s.row_count ?? '—' }}</span>
          </span>
        </li>
      </ul>
      <p v-else class="webui-dx__muted">Loading spaces…</p>
    </aside>

    <!-- Main -->
    <main class="webui-dx__main">
      <header v-if="selectedSpace" class="webui-dx__head">
        <div>
          <h1 class="webui-dx__title">
            {{ selectedSpace.name }}
            <Tag
              :value="selectedSpace.is_sync ? 'sync' : 'async'"
              :severity="selectedSpace.is_sync ? 'success' : 'secondary'"
            />
            <Tag :value="selectedSpace.engine ?? '—'" severity="info" />
          </h1>
          <div class="webui-dx__meta">
            <span>id {{ selectedSpace.id }}</span>
            <span>{{ selectedSpace.row_count ?? '—' }} rows</span>
            <span>{{ humanBytes(selectedSpace.size_bytes) }}</span>
            <span v-if="selectedSpace.sequence">seq: {{ selectedSpace.sequence }}</span>
            <span v-if="(selectedSpace.triggers_count ?? 0) > 0">
              {{ selectedSpace.triggers_count }} trigger(s)
            </span>
          </div>
        </div>
        <div class="webui-dx__actions">
          <Button
            label="Edit space"
            icon="pi pi-cog"
            severity="info"
            size="small"
            text
            :disabled="selectedSpace.name.startsWith('_')"
            @click="openAlterSpace(selectedSpace)"
          />
          <Button
            label="Drop"
            icon="pi pi-trash"
            severity="danger"
            size="small"
            text
            :disabled="selectedSpace.name.startsWith('_')"
            @click="dropSpace(selectedSpace)"
          />
          <Button
            label="New tuple"
            icon="pi pi-plus"
            severity="success"
            size="small"
            :disabled="selectedSpace.name.startsWith('_')"
            @click="openCreate"
          />
        </div>
      </header>

      <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

      <!-- Filter bar — every control rendered at PrimeVue's
           `small` size so the dense toolbar reads as one
           horizontal band instead of a mix of 32 / 40px
           controls. The Add button used to be the only `small`
           one which made it visibly squat next to the medium
           Selects / InputText. -->
      <div v-if="selectedSpace" class="webui-dx__filters">
        <Select
          v-model="newFilterField"
          :options="fieldOptions"
          option-label="label"
          option-value="value"
          placeholder="field"
          size="small"
          class="webui-dx__filter-field"
        />
        <Select
          v-model="newFilterOp"
          :options="OP_OPTIONS"
          option-label="label"
          option-value="value"
          size="small"
          class="webui-dx__filter-op"
        />
        <InputText
          v-model="newFilterValue"
          placeholder="value"
          size="small"
          class="webui-dx__filter-value"
          @keyup.enter="addFilterChip"
        />
        <Button
          label="Add"
          icon="pi pi-filter"
          size="small"
          :disabled="!newFilterField"
          @click="addFilterChip"
        />
        <label class="webui-dx__full-scan">
          <ToggleSwitch v-model="allowFullScan" @update:model-value="loadTuples" />
          <span>allow full scan</span>
        </label>
      </div>

      <div v-if="filterChips.length > 0" class="webui-dx__chips">
        <!-- Chip with `removable` exposes a built-in ✕ button and an
             `@remove` event, replacing the old "click anywhere on
             the Tag to drop it" pattern that surprised first-time
             users (clicking the value text removed the filter). -->
        <Chip
          v-for="(c, idx) in filterChips"
          :key="idx"
          :label="`${c.field} ${c.op} ${c.value}`"
          removable
          @remove="removeFilterChip(idx)"
        />
      </div>

      <div v-if="selectedSpace && indexUsed !== null" class="webui-dx__index-hint">
        <Tag :value="`index: ${indexUsed}`" severity="secondary" />
        <Tag v-if="partialScan" value="partial scan" severity="warn" />
        <Tag v-if="truncated" value="page truncated" severity="warn" />
        <Tag v-if="totalRows !== null" :value="`total: ${totalRows}`" severity="info" />
      </div>

      <!-- Tuple grid -->
      <DataTable
        v-if="selectedSpace"
        :value="tuples"
        :loading="loadingTuples"
        size="small"
        striped-rows
        :row-hover="true"
        class="webui-dx__grid"
      >
        <Column header="PK" :style="{ width: '14rem' }">
          <template #body="{ data }">
            <code class="webui-dx__pk">{{ data.pk_string }}</code>
          </template>
        </Column>
        <Column v-for="(f, i) in selectedSpace.format ?? []" :key="f.name" :header="f.name">
          <template #body="{ data }">
            <span :class="{ 'webui-dx__null': (data.fields[i] ?? null) === null }">
              {{ renderField(data.fields[i]) }}
            </span>
          </template>
        </Column>
        <Column header="" :style="{ width: '8rem' }">
          <template #body="{ data }">
            <span class="webui-dx__row-actions">
              <Button
                icon="pi pi-pencil"
                severity="info"
                text
                size="small"
                aria-label="Edit"
                :disabled="selectedSpace?.name.startsWith('_')"
                @click="openEdit(data)"
              />
              <Button
                icon="pi pi-trash"
                severity="danger"
                text
                size="small"
                aria-label="Delete"
                :disabled="selectedSpace?.name.startsWith('_')"
                @click="deleteRow(data)"
              />
            </span>
          </template>
        </Column>
        <template #empty>
          <span class="webui-dx__muted">No tuples match the current filter.</span>
        </template>
      </DataTable>

      <!-- Pagination -->
      <div v-if="selectedSpace" class="webui-dx__pager">
        <Button
          label="Prev"
          icon="pi pi-chevron-left"
          size="small"
          :disabled="cursorStack.length === 0"
          @click="prevPage"
        />
        <Button
          label="Next"
          icon="pi pi-chevron-right"
          icon-pos="right"
          size="small"
          :disabled="nextCursor === null"
          @click="nextPage"
        />
        <span class="webui-dx__muted webui-dx__page-size">
          page size:
          <Select
            v-model="pageSize"
            :options="PAGE_SIZE_OPTIONS"
            option-label="label"
            option-value="value"
            class="webui-dx__page-size-select"
            @change="loadTuples"
          />
        </span>
        <span v-if="selfInstance" class="webui-dx__muted">
          connected to: <code>{{ selfInstance }}</code>
        </span>
      </div>

      <TupleForm
        v-if="tupleFormOpen && selectedSpace"
        v-model:visible="tupleFormOpen"
        :space="selectedSpace"
        :mode="tupleFormMode"
        :initial-fields="tupleFormInitial"
        @saved="onTupleFormSaved"
      />
      <SpaceForm
        v-if="spaceFormOpen"
        v-model:visible="spaceFormOpen"
        :mode="spaceFormMode"
        :source="spaceFormSource"
        @saved="onSpaceFormSaved"
      />
    </main>
  </section>
</template>

<style scoped>
.webui-dx {
  display: grid;
  grid-template-columns: 280px 1fr;
  /* Page lives inside `<main class="webui-shell__main">`, which is
     a column flexbox with `flex: 1`. Taking `flex: 1` here makes
     the data-explorer fill that available height instead of
     guessing a `100vh - <topbar>` offset that breaks across
     viewports / topbar paddings. */
  flex: 1;
  min-height: 0;
  height: 100%;
}
.webui-dx__sidebar {
  border-right: 1px solid var(--webui-border);
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  overflow: hidden;
}
.webui-dx__sidebar-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.webui-dx__sidebar-head h2 {
  margin: 0;
  font-size: 1rem;
}
.webui-dx__sidebar-tools {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
}
.webui-dx__sidebar-filter {
  width: 100%;
}
.webui-dx__list {
  list-style: none;
  padding: 0;
  margin: 0;
  overflow-y: auto;
  flex: 1 1 auto;
}
.webui-dx__list-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.4rem 0.5rem;
  border-radius: var(--webui-radius);
  cursor: pointer;
  font-size: 0.85rem;
}
.webui-dx__list-item:hover {
  background: var(--p-content-hover-background, rgba(255, 255, 255, 0.05));
}
.webui-dx__list-item.is-selected {
  background: var(--p-highlight-background, rgba(78, 168, 222, 0.2));
}
.webui-dx__list-item.is-system .webui-dx__list-name {
  color: var(--webui-text-muted);
}
.webui-dx__list-meta {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.7rem;
}
.webui-dx__list-count {
  color: var(--webui-text-muted);
}
.webui-dx__toggle {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.8rem;
  color: var(--webui-text-muted);
}
.webui-dx__main {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  overflow: hidden;
}
.webui-dx__head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 1rem;
}
.webui-dx__title {
  margin: 0;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.webui-dx__meta {
  display: flex;
  gap: 1rem;
  margin-top: 0.4rem;
  font-size: 0.8rem;
  color: var(--webui-text-muted);
}
.webui-dx__actions {
  display: flex;
  gap: 0.5rem;
}
.webui-dx__filters {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-dx__filter-field {
  min-width: 12rem;
}
.webui-dx__filter-op {
  min-width: 5rem;
}
.webui-dx__filter-value {
  min-width: 12rem;
}
.webui-dx__chips {
  display: flex;
  gap: 0.4rem;
  flex-wrap: wrap;
}
.webui-dx__index-hint {
  display: flex;
  gap: 0.4rem;
  flex-wrap: wrap;
  align-items: center;
}
.webui-dx__full-scan {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.8rem;
  color: var(--webui-text-muted);
}
.webui-dx__pk {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
}
.webui-dx__null {
  color: var(--webui-text-muted);
  font-style: italic;
}
.webui-dx__grid {
  flex: 1 1 auto;
  min-height: 0;
}
.webui-dx__pager {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  font-size: 0.8rem;
}
.webui-dx__page-size {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
}
.webui-dx__page-size-select :deep(.p-select) {
  min-width: 5rem;
}
.webui-dx__muted {
  color: var(--webui-text-muted);
}
.webui-dx__row-actions {
  display: inline-flex;
  gap: 0.25rem;
}
.webui-dx__sync-badge {
  font-size: 0.65rem;
}
</style>
