<script setup lang="ts">
// Monaco-based side-by-side YAML diff dialog. The Monaco bundle is
// already paid for by YamlEditor in the same page, so loading the diff
// editor doesn't grow the initial chunk.
//
// `open: boolean` controls visibility; the parent fetches both YAML
// payloads (current + target) and passes them in. When closed the
// editor is disposed so a future open re-mounts a fresh widget — that
// avoids stale models bleeding across compare invocations.

import { nextTick, onBeforeUnmount, ref, shallowRef, watch } from 'vue';
import type * as Monaco from 'monaco-editor';
import Button from 'primevue/button';

const props = defineProps<{
  open: boolean;
  title: string;
  originalLabel: string;
  modifiedLabel: string;
  original: string;
  modified: string;
}>();

const emit = defineEmits<{
  (e: 'close'): void;
}>();

const container = ref<HTMLElement | null>(null);
const editor = shallowRef<Monaco.editor.IStandaloneDiffEditor | null>(null);
const loading = ref(true);
let monacoMod: typeof Monaco | null = null;
let resizeObs: ResizeObserver | null = null;

const initMonacoEnv = async () => {
  // Same env shim as YamlEditor.vue — the worker module is shared
  // between the two via Monaco's MonacoEnvironment global, so the
  // diff editor doesn't ship a second worker chunk.
  const EditorWorker = (await import(
    'monaco-editor/esm/vs/editor/editor.worker?worker'
  )).default;
  (self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
  };
};

const mount = async () => {
  if (container.value == null) return;
  loading.value = true;
  await initMonacoEnv();
  monacoMod = await import('monaco-editor');
  await import('monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution');

  const originalModel = monacoMod.editor.createModel(props.original, 'yaml');
  const modifiedModel = monacoMod.editor.createModel(props.modified, 'yaml');

  editor.value = monacoMod.editor.createDiffEditor(container.value, {
    readOnly: true,
    automaticLayout: false,
    renderSideBySide: true,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    fontFamily: 'var(--webui-font-mono, "JetBrains Mono", "Fira Code", monospace)',
    fontSize: 13,
    lineNumbers: 'on',
    theme: document.body.classList.contains('webui-dark') ? 'vs-dark' : 'vs',
  });
  editor.value.setModel({ original: originalModel, modified: modifiedModel });

  if (typeof ResizeObserver !== 'undefined') {
    resizeObs = new ResizeObserver(() => editor.value?.layout());
    resizeObs.observe(container.value);
  }
  loading.value = false;
};

const dispose = () => {
  resizeObs?.disconnect();
  resizeObs = null;
  const model = editor.value?.getModel();
  if (model) {
    model.original.dispose();
    model.modified.dispose();
  }
  editor.value?.dispose();
  editor.value = null;
};

// Re-mount on every open transition. Cheaper than juggling models —
// the diff dialog is opened on user click, not on poll.
watch(() => props.open, async (open) => {
  if (open) {
    await nextTick();
    await mount();
  } else {
    dispose();
  }
});

onBeforeUnmount(dispose);

const onBackdropClick = (event: MouseEvent) => {
  if (event.target === event.currentTarget) emit('close');
};
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open"
      class="webui-diff-overlay"
      role="dialog"
      aria-modal="true"
      :aria-label="title"
      @click="onBackdropClick"
    >
      <section class="webui-diff-dialog">
        <header class="webui-diff-dialog__head">
          <div>
            <h2>{{ title }}</h2>
            <p class="webui-diff-dialog__sub">
              <span>{{ originalLabel }}</span>
              <span class="webui-diff-dialog__arrow">→</span>
              <span>{{ modifiedLabel }}</span>
            </p>
          </div>
          <Button
            icon="pi pi-times"
            size="small"
            text
            aria-label="Close diff viewer"
            @click="emit('close')"
          />
        </header>
        <div v-if="loading" class="webui-diff-dialog__loading">Loading diff…</div>
        <div ref="container" class="webui-diff-dialog__monaco" />
      </section>
    </div>
  </Teleport>
</template>

<style scoped>
.webui-diff-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.55);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2rem;
}
.webui-diff-dialog {
  width: min(95vw, 1400px);
  height: min(92vh, 900px);
  background: var(--webui-bg, #11141d);
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: var(--webui-radius, 6px);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.webui-diff-dialog__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--webui-border, #2a2f3a);
}
.webui-diff-dialog__head h2 {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
}
.webui-diff-dialog__sub {
  margin: 0.25rem 0 0;
  color: var(--webui-text-muted, #8a93a6);
  font-size: 0.8rem;
  display: flex;
  gap: 0.5rem;
  align-items: center;
}
.webui-diff-dialog__arrow {
  opacity: 0.6;
}
.webui-diff-dialog__loading {
  flex: 0 0 auto;
  padding: 1rem;
  color: var(--webui-text-muted, #8a93a6);
  font-size: 0.85rem;
}
.webui-diff-dialog__monaco {
  flex: 1 1 auto;
  width: 100%;
  height: 100%;
}
</style>
