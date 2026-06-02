<script setup lang="ts">
/**
 * /logs — Tarantool log tail with severity / search filters.
 *
 * Reads the last N lines from the file the running instance
 * writes its log to (configured via `log.to: file` in cluster
 * YAML). The page polls every refresh-interval seconds when
 * "Live tail" is on, otherwise it loads once and waits for an
 * explicit Reload click.
 *
 * Severity dropdown follows Tarantool's letter codes (F/S/E/W/
 * I/V/D); selecting "warn" returns warn + error + system +
 * fatal. The search input does a case-insensitive substring
 * match server-side so the SPA never has to ship a 5000-line
 * payload only to grep it locally.
 */
import { computed, onMounted, onUnmounted, ref, watch, nextTick } from 'vue';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import InputNumber from 'primevue/inputnumber';
import Select from 'primevue/select';
import ToggleSwitch from 'primevue/toggleswitch';
import Message from 'primevue/message';
import Tag from 'primevue/tag';

import { restClient, RestApiError } from '@/shared/api/rest/client';

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

const tail = ref<number>(200);
const level = ref<string>('');
const search = ref<string>('');
const liveTail = ref<boolean>(false);
const refreshMs = ref<number>(2000);
const stickToBottom = ref<boolean>(true);

const lines = ref<LogLine[]>([]);
const path = ref<string>('');
const fileSize = ref<number>(0);
const instance = ref<string>('');
const loading = ref<boolean>(false);
const error = ref<string | null>(null);

const LEVEL_OPTIONS = [
  { label: 'all', value: '' },
  { label: 'fatal', value: 'F' },
  { label: 'system', value: 'S' },
  { label: 'error+', value: 'E' },
  { label: 'warn+', value: 'W' },
  { label: 'info+', value: 'I' },
  { label: 'verbose+', value: 'V' },
  { label: 'debug+', value: 'D' },
];

const scroller = ref<HTMLElement | null>(null);
let timer: ReturnType<typeof setInterval> | null = null;

function classFor(line: LogLine): string {
  switch (line.level) {
    case 'F':
    case 'S':
    case 'E':
    case 'C':
      return 'webui-logs__line webui-logs__line--err';
    case 'W':
      return 'webui-logs__line webui-logs__line--warn';
    case 'V':
    case 'D':
      return 'webui-logs__line webui-logs__line--muted';
    default:
      return 'webui-logs__line';
  }
}

function bytesFmt(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${(n / 1024 / 1024).toFixed(1)} MiB`;
}

async function load(): Promise<void> {
  loading.value = true;
  error.value = null;
  try {
    const qs = new URLSearchParams();
    qs.set('tail', String(tail.value));
    if (level.value !== '') qs.set('level', level.value);
    if (search.value !== '') qs.set('search', search.value);
    const res = await restClient.get<TailResponse>(`/api/logs?${qs.toString()}`);
    lines.value = res.lines;
    path.value = res.path;
    fileSize.value = res.file_size;
    instance.value = res.instance ?? '';
    if (stickToBottom.value) {
      await nextTick();
      const el = scroller.value;
      if (el !== null) el.scrollTop = el.scrollHeight;
    }
  } catch (e) {
    if (e instanceof RestApiError) {
      error.value = e.message;
    } else {
      error.value = (e as Error).message;
    }
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

onMounted(() => {
  void load();
});
onUnmounted(stopTimer);

const downloadHref = computed(() => {
  const p = new URLSearchParams();
  p.set('tail', String(tail.value));
  if (level.value !== '') p.set('level', level.value);
  if (search.value !== '') p.set('search', search.value);
  return `/api/logs?${p.toString()}`;
});
</script>

<template>
  <section class="webui-logs">
    <header class="webui-logs__head">
      <h1>Tarantool log</h1>
      <div class="webui-logs__meta">
        <Tag v-if="instance" :value="`instance: ${instance}`" severity="info" />
        <Tag v-if="path" :value="path" severity="secondary" />
        <Tag v-if="fileSize > 0" :value="bytesFmt(fileSize)" severity="secondary" />
      </div>
    </header>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <div class="webui-logs__bar">
      <Select
        v-model="level"
        :options="LEVEL_OPTIONS"
        option-label="label"
        option-value="value"
        size="small"
        class="webui-logs__bar-level"
      />
      <InputText
        v-model="search"
        size="small"
        placeholder="search…"
        class="webui-logs__bar-search"
        @keyup.enter="load"
      />
      <InputNumber
        v-model="tail"
        size="small"
        :min="50"
        :max="5000"
        :step="50"
        :use-grouping="false"
        class="webui-logs__bar-tail"
      />
      <Button label="Reload" icon="pi pi-refresh" size="small" :loading="loading" @click="load" />
      <label class="webui-logs__bar-toggle">
        <ToggleSwitch v-model="liveTail" />
        <span>Live tail</span>
      </label>
      <label v-if="liveTail" class="webui-logs__bar-toggle">
        <InputNumber
          v-model="refreshMs"
          size="small"
          :min="500"
          :max="10000"
          :step="500"
          :use-grouping="false"
          class="webui-logs__bar-interval"
        />
        <span>ms</span>
      </label>
      <label class="webui-logs__bar-toggle">
        <ToggleSwitch v-model="stickToBottom" />
        <span>Auto-scroll</span>
      </label>
      <Button
        as="a"
        :href="downloadHref"
        label="Raw"
        icon="pi pi-download"
        size="small"
        severity="secondary"
        text
        target="_blank"
        rel="noopener"
      />
    </div>

    <div ref="scroller" class="webui-logs__scroller">
      <div v-if="lines.length === 0 && !loading" class="webui-logs__empty">
        No log lines match the current filter.
      </div>
      <pre v-for="(ln, idx) in lines" :key="idx" :class="classFor(ln)">{{ ln.text }}</pre>
    </div>
  </section>
</template>

<style scoped>
.webui-logs {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  height: 100%;
  min-height: 0;
}
.webui-logs__head {
  display: flex;
  align-items: center;
  gap: 1rem;
  flex-wrap: wrap;
}
.webui-logs__head h1 {
  margin: 0;
}
.webui-logs__meta {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
  align-items: center;
}
.webui-logs__bar {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  flex-wrap: wrap;
}
.webui-logs__bar-level {
  min-width: 8rem;
}
.webui-logs__bar-search {
  min-width: 16rem;
  flex: 1 1 16rem;
}
.webui-logs__bar-tail {
  width: 6rem;
}
.webui-logs__bar-interval {
  width: 5rem;
}
.webui-logs__bar-toggle {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.85rem;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-logs__scroller {
  flex: 1 1 auto;
  min-height: 20rem;
  overflow: auto;
  background: var(--p-surface-950, #0a0a0a);
  border: 1px solid var(--p-content-border-color, var(--webui-border));
  border-radius: var(--p-content-border-radius, 6px);
  padding: 0.5rem 0.75rem;
}
.webui-logs__empty {
  padding: 1.5rem;
  text-align: center;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-logs__line {
  margin: 0;
  padding: 0.05rem 0;
  font-family: var(--webui-font-mono);
  font-size: 0.78rem;
  line-height: 1.45;
  white-space: pre-wrap;
  word-break: break-all;
  color: var(--p-text-color, inherit);
}
.webui-logs__line--err {
  color: #f87171;
}
.webui-logs__line--warn {
  color: #fbbf24;
}
.webui-logs__line--muted {
  color: var(--p-text-muted-color, #94a3b8);
}
</style>
