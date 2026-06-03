<script setup lang="ts">
/**
 * /logs — Tarantool log tail.
 *
 * Toolbar has two simple rows of PrimeVue controls (filters +
 * actions on top, viewing options below). The body is the shared
 * LogViewer widget — read-only Monaco themed to match PrimeVue.
 */
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import InputNumber from 'primevue/inputnumber';
import Select from 'primevue/select';
import ToggleSwitch from 'primevue/toggleswitch';
import Message from 'primevue/message';
import Tag from 'primevue/tag';

import { restClient, RestApiError } from '@/shared/api/rest/client';
import { getClient } from '@/shared/api/graphql';
import { LogViewer } from '@/widgets/log-viewer';

interface LogLine {
  text: string;
  level: string;
}

interface TailResponse {
  ok: boolean;
  instance: string | null;
  path: string;
  file_size: number;
  lines: LogLine[];
}

// `null` (not '') so PrimeVue Select shows the placeholder instead
// of an empty selected label.
const targetInstance = ref<string | null>(null);
const instanceOptions = ref<{ label: string; value: string }[]>([]);
const level = ref<string | null>(null);
const LEVEL_OPTIONS = [
  { label: 'fatal', value: 'F' },
  { label: 'system', value: 'S' },
  { label: 'error+', value: 'E' },
  { label: 'warn+', value: 'W' },
  { label: 'info+', value: 'I' },
  { label: 'verbose+', value: 'V' },
  { label: 'debug+', value: 'D' },
];

const search = ref<string>('');
const tail = ref<number>(200);

const liveTail = ref<boolean>(false);
const refreshMs = ref<number>(2000);
const stickToBottom = ref<boolean>(true);
const reverseOrder = ref<boolean>(false);

// Persist UI preferences so the operator's last setup survives a
// hard refresh. Both the read (mount) and write (watcher) wrap
// every storage call in try/catch — incognito tabs throw on
// localStorage access. Values are stored under one key as a single
// JSON blob to keep the surface tiny.
const STORAGE_KEY = 'webui.logs.prefs';
interface LogsPrefs {
  targetInstance?: string | null;
  level?: string | null;
  search?: string;
  tail?: number;
  liveTail?: boolean;
  refreshMs?: number;
  stickToBottom?: boolean;
  reverseOrder?: boolean;
}
function loadPrefs(): void {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (raw === null) return;
    const prefs = JSON.parse(raw) as LogsPrefs;
    if (typeof prefs.targetInstance === 'string' || prefs.targetInstance === null)
      targetInstance.value = prefs.targetInstance;
    if (typeof prefs.level === 'string' || prefs.level === null) level.value = prefs.level;
    if (typeof prefs.search === 'string') search.value = prefs.search;
    if (typeof prefs.tail === 'number') tail.value = prefs.tail;
    if (typeof prefs.liveTail === 'boolean') liveTail.value = prefs.liveTail;
    if (typeof prefs.refreshMs === 'number') refreshMs.value = prefs.refreshMs;
    if (typeof prefs.stickToBottom === 'boolean') stickToBottom.value = prefs.stickToBottom;
    if (typeof prefs.reverseOrder === 'boolean') reverseOrder.value = prefs.reverseOrder;
  } catch {
    /* ignore — bad JSON / private mode */
  }
}
function savePrefs(): void {
  try {
    const prefs: LogsPrefs = {
      targetInstance: targetInstance.value,
      level: level.value,
      search: search.value,
      tail: tail.value,
      liveTail: liveTail.value,
      refreshMs: refreshMs.value,
      stickToBottom: stickToBottom.value,
      reverseOrder: reverseOrder.value,
    };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    /* ignore */
  }
}

const lines = ref<LogLine[]>([]);
const path = ref<string>('');
const fileSize = ref<number>(0);
const instance = ref<string>('');
const loading = ref<boolean>(false);
const error = ref<string | null>(null);

let timer: ReturnType<typeof setInterval> | null = null;

function bytesFmt(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${(n / 1024 / 1024).toFixed(1)} MiB`;
}

const joinedText = computed(() => {
  const seq = reverseOrder.value ? [...lines.value].reverse() : lines.value;
  return seq.map((l) => l.text).join('\n');
});

const scrollAnchor = computed<'top' | 'bottom' | 'none'>(() => {
  if (!stickToBottom.value) return 'none';
  return reverseOrder.value ? 'top' : 'bottom';
});

async function load(): Promise<void> {
  loading.value = true;
  error.value = null;
  try {
    const qs = new URLSearchParams();
    qs.set('tail', String(tail.value));
    if (level.value) qs.set('level', level.value);
    if (search.value !== '') qs.set('search', search.value);
    if (targetInstance.value) qs.set('instance', targetInstance.value);
    const res = await restClient.get<TailResponse>(`/api/logs?${qs.toString()}`);
    lines.value = res.lines;
    path.value = res.path;
    fileSize.value = res.file_size;
    instance.value = res.instance ?? '';
  } catch (e) {
    error.value = e instanceof RestApiError ? e.message : (e as Error).message;
  } finally {
    loading.value = false;
  }
}

function startTimer(): void {
  stopTimer();
  if (!liveTail.value) return;
  timer = setInterval(() => {
    if (!loading.value) void load();
  }, refreshMs.value);
}
function stopTimer(): void {
  if (timer !== null) {
    clearInterval(timer);
    timer = null;
  }
}

watch(liveTail, () => {
  if (liveTail.value) startTimer();
  else stopTimer();
});
watch(refreshMs, () => {
  if (liveTail.value) startTimer();
});

// Debounced reload — fires `load()` ~300 ms after the operator
// stops typing in Search or adjusts Tail/Severity/Instance, so the
// log view updates as you change filters without spamming the
// backend on every keystroke.
let reloadDebounce: ReturnType<typeof setTimeout> | null = null;
function scheduleReload(): void {
  if (reloadDebounce !== null) clearTimeout(reloadDebounce);
  reloadDebounce = setTimeout(() => {
    void load();
  }, 300);
}
watch([search, tail, level, targetInstance], scheduleReload);

// Persist any preference change. Watching deeply on individual
// refs (not the union) avoids the noise of an initial trigger,
// since refs only fire on actual writes.
watch(
  [search, tail, level, targetInstance, liveTail, refreshMs, stickToBottom, reverseOrder],
  savePrefs,
);

async function loadInstances(): Promise<void> {
  const res = await getClient()
    .query<{
      cluster: { servers: { items: { alias: string }[] } };
    }>(
      'query LogsInstances { cluster { servers(limit: 100) { items { alias } } } }',
      {},
      { requestPolicy: 'network-only' },
    )
    .toPromise();
  if (res.error) return;
  const aliases = (res.data?.cluster?.servers?.items ?? [])
    .map((i) => i.alias)
    .filter((a) => typeof a === 'string' && a.length > 0)
    .sort();
  instanceOptions.value = aliases.map((a) => ({ label: a, value: a }));
}

onMounted(() => {
  loadPrefs();
  void loadInstances();
  void load();
  // Reapply the live-tail timer if the persisted state had it on.
  if (liveTail.value) startTimer();
});
onUnmounted(stopTimer);

const downloadHref = computed(() => {
  const p = new URLSearchParams();
  p.set('tail', String(tail.value));
  if (level.value) p.set('level', level.value);
  if (search.value !== '') p.set('search', search.value);
  if (targetInstance.value) p.set('instance', targetInstance.value);
  return `/api/logs?${p.toString()}`;
});

// Spawn a hidden anchor instead of rendering `<Button as="a">`.
// Native `<a>` inherits the browser's link line-height and ends up
// 4-5px taller than `<button>`, which makes a toolbar with mixed
// `as="a"` and default buttons look misaligned. Doing the download
// from a transient anchor keeps every visible control a real
// `<button>` and the row stays on one baseline.
function downloadRaw(): void {
  const a = document.createElement('a');
  a.href = downloadHref.value;
  a.target = '_blank';
  a.rel = 'noopener';
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    document.body.removeChild(a);
  }, 0);
}
</script>

<template>
  <section class="webui-logs">
    <header class="webui-logs__head">
      <h1>Tarantool log</h1>
      <Tag v-if="instance" :value="`instance: ${instance}`" severity="info" />
      <Tag v-if="path" :value="path" severity="secondary" />
      <Tag v-if="fileSize > 0" :value="bytesFmt(fileSize)" severity="secondary" />
    </header>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <!-- Row 1 — filters only. Each control owns the same r-field
         shape (uppercase label on top, input below) so the row reads
         as one ribbon. Search grows to absorb the leftover width. -->
    <div class="webui-logs__bar">
      <div class="webui-logs__field">
        <label for="logs-instance">Instance</label>
        <Select
          v-model="targetInstance"
          input-id="logs-instance"
          :options="instanceOptions"
          option-label="label"
          option-value="value"
          placeholder="this peer"
          size="small"
          show-clear
          class="webui-logs__select"
          @change="load"
        />
      </div>
      <div class="webui-logs__field">
        <label for="logs-level">Severity</label>
        <Select
          v-model="level"
          input-id="logs-level"
          :options="LEVEL_OPTIONS"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          show-clear
          class="webui-logs__select"
          @change="load"
        />
      </div>
      <div class="webui-logs__field webui-logs__field--grow">
        <label for="logs-search">Search</label>
        <InputText
          id="logs-search"
          v-model="search"
          size="small"
          placeholder="substring…"
          @keyup.enter="load"
        />
      </div>
      <div class="webui-logs__field">
        <label for="logs-tail">Tail lines</label>
        <InputNumber
          v-model="tail"
          input-id="logs-tail"
          size="small"
          :min="50"
          :max="5000"
          :step="50"
          :use-grouping="false"
          class="webui-logs__num"
        />
      </div>
    </div>

    <!-- Row 2 — compact single-line ribbon: toggles render with an
         inline label (no uppercase header on top, like Row 1), the
         refresh input keeps its label so the unit is obvious, and
         the action buttons sit on the same baseline as everything
         else with consistent severity. -->
    <div class="webui-logs__bar webui-logs__bar--inline">
      <label class="webui-logs__inline">
        <ToggleSwitch v-model="liveTail" input-id="logs-live" />
        <span>Live tail</span>
      </label>
      <label class="webui-logs__inline">
        <span class="webui-logs__inline-label">Refresh</span>
        <InputNumber
          v-model="refreshMs"
          input-id="logs-interval"
          size="small"
          :min="500"
          :max="10000"
          :step="500"
          :use-grouping="false"
          :disabled="!liveTail"
          class="webui-logs__num"
          suffix=" ms"
        />
      </label>
      <label class="webui-logs__inline">
        <ToggleSwitch v-model="stickToBottom" input-id="logs-autoscroll" />
        <span>Auto-scroll</span>
      </label>
      <label class="webui-logs__inline">
        <ToggleSwitch v-model="reverseOrder" input-id="logs-reverse" />
        <span>Newest first</span>
      </label>
      <div class="webui-logs__actions">
        <Button
          label="Reload"
          icon="pi pi-refresh"
          size="small"
          severity="secondary"
          outlined
          :loading="loading"
          @click="load"
        />
        <Button
          label="Raw"
          icon="pi pi-download"
          size="small"
          severity="secondary"
          outlined
          @click="downloadRaw"
        />
      </div>
    </div>

    <div class="webui-logs__viewer">
      <LogViewer
        :model-value="joinedText"
        :scroll-anchor="scrollAnchor"
        :reverse-line-numbers="reverseOrder"
      />
    </div>
  </section>
</template>

<style scoped>
.webui-logs {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  flex: 1;
  min-height: 0;
}
.webui-logs__head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-logs__head h1 {
  margin: 0;
  margin-right: 0.5rem;
}

/* Both toolbar rows share one card surface, painted from PrimeVue
   tokens. A single flex row with `flex-wrap` handles narrow viewports
   without bespoke media queries. */
.webui-logs__bar {
  display: flex;
  align-items: flex-end;
  gap: 0.75rem;
  flex-wrap: wrap;
  padding: 0.6rem 0.8rem;
  background: var(--p-content-background);
  border: 1px solid var(--p-content-border-color);
  border-radius: var(--p-content-border-radius, 6px);
}
.webui-logs__bar--view {
  align-items: center;
}

/* Every toolbar field uses the same shape: an uppercase label on
   top, the control underneath. Both rows of the toolbar agree on a
   fixed control height (matches PrimeVue `size="small"` inputs), so
   ToggleSwitch / InputNumber / Select / InputText all sit on the
   same baseline — no more bobbing controls of mixed heights. */
.webui-logs__field {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  flex: 0 0 auto;
}
.webui-logs__field--grow {
  flex: 1 1 16rem;
  min-width: 12rem;
}
.webui-logs__field > label {
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color);
  line-height: 1.1;
}
/* Every direct child that is not the label becomes the "control
   slot". Fixed min-height keeps the slot at the same vertical
   footprint regardless of which control it wraps (ToggleSwitch is
   much shorter than InputNumber by default); align-items centers
   the control vertically inside the slot. */
.webui-logs__field > :not(label) {
  display: flex;
  align-items: center;
  min-height: 2rem;
}
/* Stretch PrimeVue controls to fill their r-field wrapper so the
   fixed `min-width` on the wrapper drives the visible size, not
   the control's intrinsic default. */
.webui-logs__field > :deep(.p-select),
.webui-logs__field > :deep(.p-inputtext),
.webui-logs__field > :deep(.p-inputnumber),
.webui-logs__field > :deep(.p-inputnumber > input) {
  width: 100%;
}

.webui-logs__select {
  min-width: 9rem;
}
/* PrimeVue's InputNumber wrapper (`.p-inputnumber.p-component
   .p-inputwrapper`) and its inner `<input>` both arrive with
   higher specificity than a single-class rule, so we have to lock
   the width on both with `!important`. Without this the wrapper
   stretches to ~178px (browser default text-input size) and the
   "2000 ms" field overflows into Auto-scroll on Row 2. */
.webui-logs__num {
  width: 7rem !important;
}
.webui-logs__num :deep(input) {
  width: 100% !important;
  min-width: 0 !important;
}

.webui-logs__actions {
  display: inline-flex;
  gap: 0.5rem;
  align-items: center;
  margin-left: auto;
}

/* Row 2 is a compact single-line ribbon. The labels live next to
   their control instead of stacking on top, which keeps the bar
   close to the inputs' natural height (~2rem) instead of the 70px
   the stacked layout produced. */
.webui-logs__bar--inline {
  align-items: center;
}
.webui-logs__inline {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.85rem;
  color: var(--p-text-color);
  cursor: pointer;
}
.webui-logs__inline-label {
  font-size: 0.75rem;
  color: var(--p-text-muted-color);
}

.webui-logs__viewer {
  flex: 1;
  min-height: 14rem;
  display: flex;
}
</style>
