<script setup lang="ts">
// Monaco-based code editor / viewer. Used by the config editor
// (yaml), the Lua/SQL console (lua, sql + json viewer for the
// result panel) and any future page that wants a syntax-highlighted
// text box without the standalone Monaco bootstrap dance.
//
// Monaco itself is heavy (~600KB gzipped) so the module is loaded
// dynamically on mount — keeping it out of the initial SPA bundle.
// Workers come through Vite's native `?worker` query which Rollup
// understands at build time without a custom plugin.

import { onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import type * as Monaco from 'monaco-editor/esm/vs/editor/editor.api';

const props = withDefaults(
  defineProps<{
    modelValue: string;
    readonly?: boolean;
    height?: string;
    /**
     * Monaco language id. Defaults to `yaml` for backwards
     * compatibility with the config editor that owned this widget
     * originally. Pass `lua`, `sql`, `json`, etc. to reuse the same
     * Monaco bootstrap for a different language (console page).
     */
    language?: string;
  }>(),
  {
    readonly: false,
    height: '60vh',
    language: 'yaml',
  },
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
  /**
   * Fired when the operator presses Ctrl/Cmd+Enter while the editor
   * has focus. Monaco swallows keydown events so a parent-level
   * listener never sees the shortcut — register a Monaco command
   * here and bubble it up. Page-level handlers (e.g. Console "Run")
   * subscribe via `@submit`.
   */
  (e: 'submit'): void;
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
  monacoMod = await import('monaco-editor/esm/vs/editor/editor.api');
  // Pull in the language contribution for the requested mode. The
  // `basic-languages` package ships everything we need; importing
  // by id registers the tokenizer with Monaco. Wrapped in pcall-
  // style try because an unknown language id should fall back to
  // plain text rather than crashing the editor mount.
  try {
    switch (props.language) {
      case 'yaml':
        await import('monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution');
        break;
      case 'lua':
        await import('monaco-editor/esm/vs/basic-languages/lua/lua.contribution');
        break;
      case 'sql':
        await import('monaco-editor/esm/vs/basic-languages/sql/sql.contribution');
        break;
      case 'json':
        // JSON is an "advanced" language in Monaco — full LSP-like
        // mode with validation; lives under `language/json/`, not
        // `basic-languages/`.
        await import('monaco-editor/esm/vs/language/json/monaco.contribution');
        break;
      default:
        // Plain text — Monaco accepts the language anyway.
        break;
    }
  } catch {
    /* fall through to whatever Monaco has registered already */
  }

  editor.value = monacoMod.editor.create(container.value, {
    value: props.modelValue,
    language: props.language,
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

  // Bind Ctrl/Cmd+Enter inside Monaco's own keybinding registry —
  // a native page-level `keydown` listener never sees the shortcut
  // because Monaco intercepts the event. `KeyMod.CtrlCmd` resolves
  // to Cmd on macOS and Ctrl on Linux/Windows.
  editor.value.addCommand(monacoMod.KeyMod.CtrlCmd | monacoMod.KeyCode.Enter, () => {
    emit('submit');
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
  <div class="webui-code-editor" :style="{ height }">
    <div v-if="loading" class="webui-code-editor__loading">Loading editor…</div>
    <div ref="container" class="webui-code-editor__monaco" />
  </div>
</template>

<style scoped>
.webui-code-editor {
  position: relative;
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: var(--webui-radius, 6px);
  overflow: hidden;
  background: var(--webui-bg-elevated, #161a23);
  /* Take full width of the parent (e.g. a flex container with
     `display: flex` and `flex: 1`); without this the Monaco
     container starts at zero width and the editor never paints. */
  width: 100%;
  /* Stretch vertically too when the parent is `display: flex` —
     the `:style="{ height }"` prop only locks the height for
     non-flex parents. */
  flex: 1;
}
.webui-code-editor__monaco {
  width: 100%;
  height: 100%;
}
.webui-code-editor__loading {
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
