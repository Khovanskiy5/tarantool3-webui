<script setup lang="ts">
// Monaco-based YAML editor used by /config-editor.
//
// Monaco itself is heavy (~600KB gzipped) so the module is loaded
// dynamically on mount — keeping it out of the initial SPA bundle.
// Workers come through Vite's native `?worker` query which Rollup
// understands at build time without a custom plugin.

import { onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import type * as Monaco from 'monaco-editor';

const props = withDefaults(
  defineProps<{
    modelValue: string;
    readonly?: boolean;
    height?: string;
  }>(),
  {
    readonly: false,
    height: '60vh',
  },
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const container = ref<HTMLElement | null>(null);
const editor = shallowRef<Monaco.editor.IStandaloneCodeEditor | null>(null);
const loading = ref(true);

let monacoMod: typeof Monaco | null = null;
let suppressNextUpdate = false;
let resizeObs: ResizeObserver | null = null;

// Monaco workers run off the main thread. Vite's `?worker` query
// emits a worker chunk per import. We only need the base
// editor.worker — YAML doesn't ship language-specific workers.
const initMonacoEnv = async () => {
  const EditorWorker = (await import('monaco-editor/esm/vs/editor/editor.worker?worker')).default;
  (self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
  };
};

const mountEditor = async () => {
  if (container.value == null) return;
  await initMonacoEnv();
  monacoMod = await import('monaco-editor');
  // Basic YAML tokenization. The `basic-languages` package is
  // bundled with monaco-editor — registering by id is enough.
  await import('monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution');

  editor.value = monacoMod.editor.create(container.value, {
    value: props.modelValue,
    language: 'yaml',
    readOnly: props.readonly,
    automaticLayout: false,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    fontFamily: 'var(--webui-font-mono, "JetBrains Mono", "Fira Code", monospace)',
    fontSize: 13,
    lineNumbers: 'on',
    renderWhitespace: 'boundary',
    tabSize: 2,
    insertSpaces: true,
    wordWrap: 'off',
    theme: document.body.classList.contains('webui-dark') ? 'vs-dark' : 'vs',
  });

  editor.value.onDidChangeModelContent(() => {
    if (suppressNextUpdate) {
      suppressNextUpdate = false;
      return;
    }
    const value = editor.value?.getValue() ?? '';
    emit('update:modelValue', value);
  });

  // Manual layout via ResizeObserver — Monaco's automaticLayout
  // is a polling loop that wastes a frame budget.
  if (typeof ResizeObserver !== 'undefined') {
    resizeObs = new ResizeObserver(() => editor.value?.layout());
    resizeObs.observe(container.value);
  }

  loading.value = false;
};

// External writes to v-model (e.g. Reload button) must not echo
// back through the change emitter, otherwise the editor and parent
// fight over cursor position.
watch(
  () => props.modelValue,
  (next) => {
    if (editor.value == null) return;
    if (editor.value.getValue() === next) return;
    suppressNextUpdate = true;
    editor.value.setValue(next);
  },
);

watch(
  () => props.readonly,
  (next) => {
    editor.value?.updateOptions({ readOnly: next });
  },
);

onMounted(() => {
  void mountEditor();
});

onBeforeUnmount(() => {
  resizeObs?.disconnect();
  editor.value?.dispose();
  editor.value = null;
});
</script>

<template>
  <div class="webui-yaml-editor" :style="{ height }">
    <div v-if="loading" class="webui-yaml-editor__loading">Loading editor…</div>
    <div ref="container" class="webui-yaml-editor__monaco" />
  </div>
</template>

<style scoped>
.webui-yaml-editor {
  position: relative;
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: var(--webui-radius, 6px);
  overflow: hidden;
  background: var(--webui-bg-elevated, #161a23);
}
.webui-yaml-editor__monaco {
  width: 100%;
  height: 100%;
}
.webui-yaml-editor__loading {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--webui-text-muted, #8a93a6);
  font-size: 0.9rem;
  z-index: 1;
}
</style>
