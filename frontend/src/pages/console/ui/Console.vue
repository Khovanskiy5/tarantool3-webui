<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import Button from 'primevue/button';
import SelectButton from 'primevue/selectbutton';
import Message from 'primevue/message';
import Tag from 'primevue/tag';
import ToggleSwitch from 'primevue/toggleswitch';
import Splitter from 'primevue/splitter';
import SplitterPanel from 'primevue/splitterpanel';

import { restClient, RestApiError } from '@/shared/api/rest/client';
import { CodeEditor } from '@/widgets/code-editor';

// Per-language defaults mirror each other: both return the local
// instance's name+uuid so an operator switching the SelectButton
// gets an identity probe in either dialect.
const DEFAULT_LUA = 'return box.info.name, box.info.uuid';
const DEFAULT_SQL = 'SELECT "name", "uuid" FROM "_cluster"';

const lang = ref<'lua' | 'sql'>('lua');
const code = ref(DEFAULT_LUA);
const running = ref(false);
const result = ref<unknown>(null);
const errorMsg = ref<string | null>(null);
const latency = ref<number | null>(null);
const instance = ref<string | null>(null);

// Sticky toggle. Same semantics as /sql page — when on, every
// Run sends seqscan_allowed: true. Only meaningful for lang=sql.
const allowFullScan = ref(false);

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

// True when the last SQL eval failed with Tarantool's full-scan
// guard. Same heuristic the /sql page uses — message contains
// "scanning is not allowed" (the wording the runtime ships).
const seqscanRequired = computed(() => {
  if (lang.value !== 'sql' || !errorMsg.value) return false;
  const s = errorMsg.value.toLowerCase();
  return (
    s.includes('scanning is not allowed') || s.includes('seqscan') || s.includes('sql_seq_scan')
  );
});

// Pretty-printed JSON of the latest result — passed straight into
// the read-only Monaco viewer so it gets syntax highlighting,
// virtual scroll, and a familiar surface for picking values.
const resultText = computed(() =>
  result.value === null ? '' : JSON.stringify(result.value, null, 2),
);

const run = async (opts: { seqscanAllowed?: boolean } = {}) => {
  running.value = true;
  errorMsg.value = null;
  result.value = null;
  try {
    const res = await restClient.post<EvalResp>(
      '/api/eval',
      {
        code: code.value,
        lang: lang.value,
        // Backend honours seqscan_allowed only when lang=sql; safe
        // to send unconditionally.
        seqscan_allowed: opts.seqscanAllowed === true || allowFullScan.value,
      },
      { handlers: { onForbidden: () => {} } },
    );
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

// Ctrl/Cmd+Enter is wired inside Monaco itself via the CodeEditor
// widget's `addCommand` call, which then emits a `submit` event
// the template handles directly on the `<CodeEditor>` instance.
// A page-level `keydown` listener cannot catch the shortcut because
// Monaco intercepts the event before it bubbles.
</script>

<template>
  <section class="webui-console">
    <header class="webui-console__head">
      <h1>Lua / SQL console</h1>
      <SelectButton v-model="lang" :options="['lua', 'sql']" :allow-empty="false" size="small" />
    </header>

    <Message severity="warn" :closable="false">
      Console runs against the local instance with full privileges. Every eval is recorded in
      <code>_webui_audit</code>. Disabled by default; flip
      <code>roles_cfg.webui.console_enabled</code> to enable.
    </Message>

    <div class="webui-console__actions">
      <Button :loading="running" icon="pi pi-play" :label="`Run (${lang})`" @click="() => run()" />
      <label v-if="lang === 'sql'" class="webui-console__option">
        <ToggleSwitch v-model="allowFullScan" input-id="console-fullscan" />
        <span>allow full scan</span>
      </label>
      <span class="webui-console__hint">Ctrl/Cmd+Enter to run</span>
    </div>

    <!-- Vertical split: editor on top, result panel below. Always
         rendered — even before the first Run — so the operator sees
         a clear "result lands here" affordance instead of having to
         scroll down past the editor to find it. Drag the bar to
         resize. -->
    <Splitter layout="vertical" class="webui-console__split">
      <SplitterPanel :size="60" :min-size="20">
        <div class="webui-console__pane">
          <CodeEditor v-model="code" :language="lang" height="100%" @submit="run()" />
        </div>
      </SplitterPanel>
      <SplitterPanel :size="40" :min-size="15">
        <div class="webui-console__pane webui-console__result-pane">
          <header class="webui-console__result-head">
            <h2>Result</h2>
            <Tag v-if="instance" :value="`instance: ${instance}`" severity="info" />
            <Tag
              v-if="latency !== null"
              :value="`latency: ${latency.toFixed(1)} ms`"
              severity="secondary"
            />
          </header>
          <Message
            v-if="seqscanRequired"
            severity="warn"
            :closable="false"
            class="webui-console__seqscan"
          >
            <strong>Sequence scan required.</strong>
            Tarantool blocks full-scan SELECTs by default (<code>sql_seq_scan = false</code>).
            Re-run with the toggle enabled for this call only — the session setting is restored
            after the response.
            <Button
              label="Re-run with SEQSCAN"
              icon="pi pi-refresh"
              size="small"
              severity="warn"
              @click="run({ seqscanAllowed: true })"
            />
          </Message>
          <Message v-if="errorMsg && !seqscanRequired" severity="error" :closable="false">
            {{ errorMsg }}
          </Message>
          <div v-if="resultText !== ''" class="webui-console__result-viewer">
            <CodeEditor :model-value="resultText" language="json" readonly height="100%" />
          </div>
          <p v-else-if="result === null && errorMsg === null" class="webui-console__result-empty">
            Run a query (Ctrl/Cmd+Enter) — the result will appear here.
          </p>
        </div>
      </SplitterPanel>
    </Splitter>
  </section>
</template>

<style scoped>
.webui-console {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  flex: 1;
  min-height: 0;
}
.webui-console__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.webui-console__head h1 {
  margin: 0;
}
/* The vertical splitter owns the remaining page height — top
   panel holds the editor, bottom panel holds the result. Both
   panes use `display: flex` so the CodeEditor inside them can
   stretch to 100% on their own without per-pane size guesses. */
.webui-console__split {
  flex: 1;
  min-height: 14rem;
}
/* PrimeVue Splitter ships its own surface (white background +
   slate-200 border by default) — not bridged to the project's
   dark theme. Vue forwards `webui-console__split` onto the same
   `<div>` that carries `.p-splitter`, so we style directly here
   (descendant `:deep` would not match, both classes live on the
   same element). */
.webui-console__split {
  background: transparent;
  border: none;
}
.webui-console__split :deep(.p-splitter-gutter) {
  background: var(--p-content-border-color, var(--webui-border));
}
.webui-console__split :deep(.p-splitter-gutter-handle) {
  background: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-console__pane {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
}
.webui-console__result-pane {
  gap: 0.5rem;
  padding: 0.5rem 0;
}
.webui-console__actions {
  display: flex;
  align-items: center;
  gap: 1rem;
  flex-wrap: wrap;
}
.webui-console__option {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.85rem;
  color: var(--p-text-color, var(--webui-text));
  cursor: pointer;
}
.webui-console__hint {
  color: var(--p-text-muted-color, var(--webui-text-muted));
  font-size: 0.85rem;
}
.webui-console__seqscan :deep(.p-message-text) {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.webui-console__result-head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-console__result-head h2 {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
}
/* The viewer fills whatever space the result pane's header +
   message banners leave behind — splitter-managed, no fixed height. */
.webui-console__result-viewer {
  flex: 1;
  min-height: 0;
  display: flex;
}
.webui-console__result-empty {
  color: var(--p-text-muted-color, var(--webui-text-muted));
  font-size: 0.85rem;
  margin: 0;
}
</style>
