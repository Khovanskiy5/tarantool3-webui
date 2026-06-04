<script setup lang="ts">
// Monaco-based viewer for Tarantool log lines.
//
// Mirrors the CodeEditor pattern from the config-editor page —
// dynamic import keeps Monaco out of the initial bundle, manual
// ResizeObserver replaces Monaco's automaticLayout polling — but
// runs in read-only mode and auto-scrolls to the bottom when the
// parent asks for it. The host page owns the polling cadence and
// only feeds us the joined text + a `stickToBottom` flag.

import { onBeforeUnmount, onMounted, ref, shallowRef, watch, nextTick } from 'vue';
import type * as Monaco from 'monaco-editor/esm/vs/editor/editor.api';

const props = withDefaults(
  defineProps<{
    /** Joined log text (one line per `\n`). */
    modelValue: string;
    /**
     * Where to keep the viewport pinned after every content update.
     * `bottom` — newest line visible (chronological order).
     * `top`    — newest line visible when the host already reversed
     *            the buffer (newest-first listing).
     * `none`   — leave the scroll position alone (operator scrolled
     *            mid-buffer; don't jump them around).
     */
    scrollAnchor?: 'top' | 'bottom' | 'none';
    /**
     * When true the gutter numbers count down (N..1) instead of up,
     * matching a "newest first" buffer. The top row stays "N" so it
     * reads as "this is line N of the original chronological stream".
     */
    reverseLineNumbers?: boolean;
  }>(),
  { scrollAnchor: 'bottom', reverseLineNumbers: false },
);

const container = ref<HTMLElement | null>(null);
const editor = shallowRef<Monaco.editor.IStandaloneCodeEditor | null>(null);
const loading = ref(true);
let monacoMod: typeof Monaco | null = null;
let resizeObs: ResizeObserver | null = null;
// Decorations are referenced by id so we can replace them on every
// cursor change — see workaround #2 in `mountEditor`.
let lineDecorations: string[] = [];

const initMonacoEnv = async () => {
  const EditorWorker = (await import('monaco-editor/esm/vs/editor/editor.worker?worker')).default;
  (self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
  };
};

// Resolve a CSS custom property declared on `<body>` and trim the
// browser's whitespace. Returns the fallback when the token is not
// set (storybook / isolated tests where the PrimeVue theme has not
// loaded yet).
const cssVar = (name: string, fallback: string): string => {
  const v = getComputedStyle(document.body).getPropertyValue(name).trim();
  return v.length > 0 ? v : fallback;
};

// Register a Monaco theme that pulls its background, foreground and
// accent from PrimeVue tokens (`--p-surface-*`, `--p-text-*`,
// `--p-content-border-color`). This keeps the editor surface in
// lockstep with the rest of the SPA chrome — switching the theme
// picker re-paints the editor on the next mount.
const registerWebuiTheme = (m: typeof Monaco): string => {
  const isDark = document.body.classList.contains('webui-dark');
  const themeId = isDark ? 'webui-dark' : 'webui-light';
  const bg = cssVar(isDark ? '--p-surface-950' : '--p-surface-50', isDark ? '#0a0a0a' : '#ffffff');
  const fg = cssVar('--p-text-color', isDark ? '#e5e7eb' : '#111827');
  const muted = cssVar('--p-text-muted-color', isDark ? '#8a93a6' : '#6b7280');
  const border = cssVar('--p-content-border-color', isDark ? '#2a2f3a' : '#e5e7eb');
  // Subtle selection — must be a #RRGGBBAA value so Monaco renders
  // it as a translucent overlay. Using the project highlight token
  // directly painted a saturated coral stripe over the row.
  const selection = isDark ? '#2a2f3a80' : '#cce4ff80';
  m.editor.defineTheme(themeId, {
    base: isDark ? 'vs-dark' : 'vs',
    inherit: true,
    rules: [{ token: '', foreground: fg.replace('#', ''), background: bg.replace('#', '') }],
    colors: {
      'editor.background': bg,
      'editor.foreground': fg,
      'editorLineNumber.foreground': muted,
      // Active gutter number uses the regular text colour so the
      // operator can see which line the cursor is on at a glance.
      'editorLineNumber.activeForeground': fg,
      'editorGutter.background': bg,
      'editor.selectionBackground': selection,
      'editor.inactiveSelectionBackground': selection,
      'editorIndentGuide.background': border,
      'editorIndentGuide.activeBackground': border,
      'scrollbarSlider.background': border,
    },
  });
  return themeId;
};

// Build the `lineNumbers` callback Monaco wants. When the host shows
// the buffer in reverse order, the gutter counts down (N..1) so the
// number still reflects the line's position in the original
// chronological stream — handy for spotting "this is line 199 of 200".
const lineNumberFn = (): ((n: number) => string) => {
  return (n: number) => {
    if (!props.reverseLineNumbers) return String(n);
    const model = editor.value?.getModel();
    const total = model?.getLineCount() ?? n;
    return String(total - n + 1);
  };
};

const applyAnchor = () => {
  if (editor.value == null) return;
  if (props.scrollAnchor === 'none') return;
  const model = editor.value.getModel();
  if (model == null) return;
  if (props.scrollAnchor === 'top') {
    editor.value.revealLine(1);
    return;
  }
  editor.value.revealLine(model.getLineCount());
};

const mountEditor = async () => {
  if (container.value == null) return;
  await initMonacoEnv();
  monacoMod = await import('monaco-editor/esm/vs/editor/editor.api');

  const themeId = registerWebuiTheme(monacoMod);
  editor.value = monacoMod.editor.create(container.value, {
    value: props.modelValue,
    language: 'plaintext',
    readOnly: true,
    // `domReadOnly: true` blocks browser editing primitives (paste,
    // composition) on top of `readOnly: true`. Together they make
    // Monaco behave like a "log viewer", not a code editor.
    domReadOnly: true,
    automaticLayout: false,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    fontFamily: 'var(--webui-font-mono, "JetBrains Mono", "Fira Code", monospace)',
    fontSize: 12,
    lineNumbers: lineNumberFn(),
    wordWrap: 'on',
    // Viewer-grade chrome: keep the caret so arrow keys navigate
    // row-by-row. Disable Monaco's own `renderLineHighlight`
    // because for wrapped lines it only paints the visual row the
    // cursor sits in — we paint the whole logical line (text area
    // + gutter) ourselves via decorations on cursor change.
    renderLineHighlight: 'none',
    cursorBlinking: 'solid',
    occurrencesHighlight: 'off',
    selectionHighlight: false,
    matchBrackets: 'never',
    folding: false,
    glyphMargin: false,
    contextmenu: false,
    // Log viewer extras: smooth scrolling for the autoscroll jumps,
    // no bracket colourization (plain-text has nothing to colour and
    // the algorithm allocates per render), and overflow widgets
    // fixed to the viewport so tooltips never escape into the
    // toolbar area above.
    bracketPairColorization: { enabled: false },
    smoothScrolling: true,
    fixedOverflowWidgets: true,
    theme: themeId,
  });

  // Workaround #1 (microsoft/monaco-editor#1499): clicking a gutter
  // line number positions the cursor at the *end* of that line, so
  // the line-highlight paints on the *next* row because the cursor
  // logically sits past the EOL. Snap to column 1 of the clicked
  // line so the active row matches the click.
  editor.value.onMouseDown((e) => {
    const m = monacoMod;
    if (m == null) return;
    if (e.target.type !== m.editor.MouseTargetType.GUTTER_LINE_NUMBERS) return;
    const pos = e.target.position;
    if (pos == null) return;
    editor.value?.setPosition({ lineNumber: pos.lineNumber, column: 1 });
  });

  // Workaround #2: Monaco's `renderLineHighlight: 'all'` paints only
  // the *visual* row of the cursor, not the whole logical line — so
  // wrapped log entries only get the cursor's half highlighted.
  //
  // Paint the active row ourselves with an `isWholeLine` decoration
  // that hits both the text area (`className`) AND the gutter
  // background (`marginClassName`). `isWholeLine: true` makes the
  // decoration span every visual row of the wrapped logical line —
  // exactly what an operator expects when clicking a multi-row entry.
  editor.value.onDidChangeCursorPosition((e) => {
    const m = monacoMod;
    if (m == null || editor.value == null) return;
    const line = e.position.lineNumber;
    lineDecorations = editor.value.deltaDecorations(lineDecorations, [
      {
        range: new m.Range(line, 1, line, 1),
        options: {
          isWholeLine: true,
          className: 'webui-log-active-line',
          marginClassName: 'webui-log-active-margin',
        },
      },
    ]);
  });

  if (typeof ResizeObserver !== 'undefined') {
    resizeObs = new ResizeObserver(() => editor.value?.layout());
    resizeObs.observe(container.value);
  }

  loading.value = false;
  await nextTick();
  applyAnchor();
};

watch(
  () => props.modelValue,
  async (next) => {
    if (editor.value == null) return;
    if (editor.value.getValue() === next) return;
    editor.value.setValue(next);
    await nextTick();
    applyAnchor();
  },
);
// Re-apply when the host flips between bottom/top (e.g. reverse
// toggle) without waiting for the next data tick.
watch(
  () => props.scrollAnchor,
  async () => {
    await nextTick();
    applyAnchor();
  },
);

// `lineNumbers` is captured by reference at construction time —
// flipping `reverseLineNumbers` needs an explicit `updateOptions`
// call to re-render the gutter.
watch(
  () => props.reverseLineNumbers,
  () => {
    editor.value?.updateOptions({ lineNumbers: lineNumberFn() });
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
  <div class="webui-log-viewer">
    <div v-if="loading" class="webui-log-viewer__loading">Loading editor…</div>
    <div ref="container" class="webui-log-viewer__monaco" />
  </div>
</template>

<style scoped>
.webui-log-viewer {
  position: relative;
  width: 100%;
  height: 100%;
  border: 1px solid var(--p-content-border-color, var(--webui-border, #2a2f3a));
  border-radius: var(--p-content-border-radius, 6px);
  overflow: hidden;
  background: var(--p-surface-950, #0a0a0a);
}
.webui-log-viewer__monaco {
  width: 100%;
  height: 100%;
}

/* Painted by an `isWholeLine: true` decoration set on every cursor
   move (see `mountEditor`). Unlike Monaco's built-in line highlight,
   the decoration covers ALL visual rows of a wrapped log entry —
   both in the text area (`className`) and in the gutter / line-number
   strip (`marginClassName`). The classes are global because Monaco
   injects the decoration <div>s into an overlay outside the Vue
   component's data-scoped subtree. */
:global(.monaco-editor .webui-log-active-line),
:global(.monaco-editor .webui-log-active-margin) {
  background: var(--p-content-hover-background, rgba(255, 255, 255, 0.06));
}
.webui-log-viewer__loading {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--p-text-muted-color, var(--webui-text-muted, #8a93a6));
  font-size: 0.9rem;
  z-index: 1;
}
</style>
