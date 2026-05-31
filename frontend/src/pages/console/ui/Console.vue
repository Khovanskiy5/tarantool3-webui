<script setup lang="ts">
import { ref } from 'vue';
import Button from 'primevue/button';
import SelectButton from 'primevue/selectbutton';
import Message from 'primevue/message';
import Textarea from 'primevue/textarea';

import { restClient, RestApiError } from '@/shared/api/rest/client';

// Per-language defaults mirror each other: both return the local
// instance's name+uuid so an operator switching the SelectButton
// gets an identity probe in either dialect. The SQL flavor uses
// the built-in `_cluster` system table — it's the closest SQL has
// to `box.info`. Tarantool 3.x does not expose `box.info` via SQL
// scalar functions, so the system view is the only stable surface.
const DEFAULT_LUA = 'return box.info.name, box.info.uuid';
const DEFAULT_SQL = 'SELECT "name", "uuid" FROM "_cluster"';

const lang = ref<'lua' | 'sql'>('lua');
const code = ref(DEFAULT_LUA);
const running = ref(false);
const result = ref<unknown>(null);
const errorMsg = ref<string | null>(null);
const latency = ref<number | null>(null);
const instance = ref<string | null>(null);
const sqlPlaceholder = 'SELECT * FROM "_space" LIMIT 5';

import { watch } from 'vue';
// Swap defaults on language toggle, but ONLY when the buffer is
// unchanged from the previous language's default — typed user
// content stays put across toggles.
watch(lang, (next, prev) => {
  const prevDefault = prev === 'lua' ? DEFAULT_LUA : DEFAULT_SQL;
  const nextDefault = next === 'lua' ? DEFAULT_LUA : DEFAULT_SQL;
  if (code.value.trim() === prevDefault.trim()) code.value = nextDefault;
});

interface EvalResp {
  ok: boolean;
  result: unknown;
  error?: string;
  latency_ms: number;
  instance?: string;
}

const run = async () => {
  running.value = true;
  errorMsg.value = null;
  result.value = null;
  try {
    const res = await restClient.post<EvalResp>('/api/eval', {
      code: code.value, lang: lang.value,
    }, { handlers: { onForbidden: () => {} } });
    latency.value = res.latency_ms;
    instance.value = res.instance ?? null;
    if (res.ok) {
      result.value = res.result;
    } else {
      errorMsg.value = res.error ?? 'unknown error';
    }
  } catch (e) {
    if (e instanceof RestApiError) {
      errorMsg.value = `${e.code}: ${e.message}`;
    } else {
      errorMsg.value = (e as Error).message;
    }
  } finally {
    running.value = false;
  }
};

const onKeydown = (ev: KeyboardEvent) => {
  if ((ev.ctrlKey || ev.metaKey) && ev.key === 'Enter') {
    ev.preventDefault();
    run();
  }
};
</script>

<template>
  <section class="webui-console">
    <header class="webui-console__head">
      <h1>Lua / SQL console</h1>
      <SelectButton v-model="lang" :options="['lua', 'sql']" :allow-empty="false" size="small" />
    </header>
    <Message severity="warn" :closable="false">
      Console runs against the local instance with full privileges. Every eval is recorded in
      <code>_webui_audit</code>. Disabled by default; flip <code>roles_cfg.webui.console_enabled</code> to enable.
    </Message>
    <Textarea
      v-model="code"
      class="webui-console__editor"
      rows="10"
      :placeholder="lang === 'lua' ? 'return box.info' : sqlPlaceholder"
      @keydown="onKeydown"
    />
    <div class="webui-console__actions">
      <Button :loading="running" icon="pi pi-play" :label="`Run (${lang})`" @click="run" />
      <span class="webui-console__hint">Ctrl/Cmd+Enter to run</span>
    </div>
    <Message v-if="errorMsg" severity="error" :closable="false">{{ errorMsg }}</Message>
    <section v-if="result !== null || errorMsg" class="webui-console__output">
      <header class="webui-console__output-head">
        <span>Result</span>
        <span v-if="instance">instance: <code>{{ instance }}</code></span>
        <span v-if="latency !== null">latency: {{ latency.toFixed(1) }} ms</span>
      </header>
      <pre>{{ result !== null ? JSON.stringify(result, null, 2) : '' }}</pre>
    </section>
  </section>
</template>

<style scoped>
.webui-console { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-console__head { display: flex; align-items: center; justify-content: space-between; }
.webui-console__head h1 { margin: 0; }
.webui-console__editor { font-family: var(--webui-font-mono); font-size: 0.9rem; }
.webui-console__actions { display: flex; align-items: center; gap: 1rem; }
.webui-console__hint { color: var(--webui-text-muted); font-size: 0.85rem; }
.webui-console__output { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 1rem; }
.webui-console__output-head { display: flex; gap: 1.5rem; color: var(--webui-text-muted); font-size: 0.85rem; padding-bottom: 0.5rem; }
.webui-console__output pre { font-family: var(--webui-font-mono); font-size: 0.85rem; margin: 0; max-height: 50vh; overflow: auto; }
</style>
