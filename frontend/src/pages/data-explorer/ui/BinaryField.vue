<script setup lang="ts">
/**
 * DE-1.2 — shared binary field editor.
 *
 * `varbinary` columns + the `_binary_base64` envelope that the
 * backend uses to escape non-UTF-8 string bytes both arrive as
 * objects shaped `{ _binary_base64: "<base64>" }`. The previous
 * TupleForm rendered that envelope through `JSON.stringify`, which
 * produced unreadable input and silently round-tripped the
 * envelope as a quoted string on save. This component models the
 * value as raw bytes and offers three switchable representations
 * plus file upload / download.
 *
 * v-model contract: the parent passes either
 *   * the envelope object `{ _binary_base64: <base64> }`, or
 *   * `null` / an empty string for "no bytes",
 * and receives back the same envelope on every edit. The envelope
 * shape is the canonical wire format the backend's `coerce_field`
 * accepts on insert / replace.
 */
import { computed, ref, watch } from 'vue';
import SelectButton from 'primevue/selectbutton';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Textarea from 'primevue/textarea';
import Message from 'primevue/message';

import {
  type BinaryEnvelope,
  base64ToBytes,
  bytesToBase64,
  envelopeOf,
  utf8DecodeStrict,
  utf8Encode,
} from './binary-helpers';

const props = defineProps<{
  modelValue: BinaryEnvelope | string | null;
  disabled?: boolean;
  // Read-only mode (DE-1.6 msgpack view): the base64 / utf-8
  // textareas become non-editable and the Upload button is hidden.
  // The view switch + Download stay so the operator can still
  // inspect the bytes in any representation and export them.
  readonly?: boolean;
  // Hide the UTF-8 view entirely (DE-1.6 msgpack view). Raw msgpack
  // is never valid UTF-8 — the framing bytes (0x92 array marker,
  // 0xa5 str marker, …) are continuation bytes — so a permanently
  // disabled "UTF-8 (invalid)" tab there is dead weight. Regular
  // binary fields keep all three tabs (UTF-8 activates when the
  // bytes happen to be text).
  hideUtf8?: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', v: BinaryEnvelope | null): void;
}>();

const view = ref<'hex' | 'base64' | 'utf8'>('hex');
const editError = ref<string | null>(null);

const base64 = computed<string>(() => envelopeOf(props.modelValue));

const bytes = computed<Uint8Array>(() => {
  if (!base64.value) return new Uint8Array();
  try {
    return base64ToBytes(base64.value);
  } catch {
    return new Uint8Array();
  }
});

const utf8Decoded = computed<string | null>(() => {
  if (bytes.value.length === 0) return '';
  return utf8DecodeStrict(bytes.value);
});

const utf8Valid = computed(() => utf8Decoded.value !== null);

const sizeLabel = computed(() => {
  const n = bytes.value.length;
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
});

const VIEW_OPTIONS = computed(() => {
  const opts: { label: string; value: string }[] = [
    { label: 'Hex', value: 'hex' },
    { label: 'Base64', value: 'base64' },
  ];
  // Show the UTF-8 tab only when the bytes actually decode as UTF-8
  // (an empty field counts as valid — the operator can type fresh
  // text). We never render a disabled "UTF-8 (invalid)" tab: it was
  // dead weight on binary payloads and the whole-tuple msgpack view
  // alike. `hideUtf8` force-hides it regardless (msgpack view).
  if (!props.hideUtf8 && utf8Valid.value) {
    opts.push({ label: 'UTF-8', value: 'utf8' });
  }
  return opts;
});

// If the UTF-8 tab disappears (bytes stopped decoding as UTF-8, or
// `hideUtf8` flipped) while it was selected, fall back to Hex so
// `view` never strands on a tab that is no longer rendered.
watch(
  () => [utf8Valid.value, props.hideUtf8] as const,
  ([valid, hidden]) => {
    if (view.value === 'utf8' && (!valid || hidden)) view.value = 'hex';
  },
);

// ─── hex render ──────────────────────────────────────────────────

interface HexRow {
  offset: string;
  bytes: string;
  ascii: string;
}

const hexRows = computed<HexRow[]>(() => {
  const out: HexRow[] = [];
  const bs = bytes.value;
  for (let i = 0; i < bs.length; i += 16) {
    const chunk = bs.subarray(i, i + 16);
    let hex = '';
    let ascii = '';
    for (let j = 0; j < chunk.length; j++) {
      hex += chunk[j].toString(16).padStart(2, '0');
      hex += j === 7 ? '  ' : ' ';
      const c = chunk[j];
      ascii += c >= 0x20 && c <= 0x7e ? String.fromCharCode(c) : '.';
    }
    out.push({
      offset: i.toString(16).padStart(8, '0'),
      bytes: hex.trimEnd(),
      ascii,
    });
  }
  return out;
});

// ─── edit handlers ───────────────────────────────────────────────

function emitBytes(next: Uint8Array | null) {
  editError.value = null;
  if (next === null || next.length === 0) {
    emit('update:modelValue', { _binary_base64: '' });
    return;
  }
  emit('update:modelValue', { _binary_base64: bytesToBase64(next) });
}

function onBase64Input(value: string) {
  editError.value = null;
  try {
    const next = base64ToBytes(value);
    emitBytes(next);
  } catch (e) {
    editError.value = 'Invalid base64: ' + (e as Error).message;
  }
}

function onUtf8Input(value: string) {
  emitBytes(utf8Encode(value));
}

// ─── file upload / download ──────────────────────────────────────

const fileInput = ref<HTMLInputElement | null>(null);

function triggerUpload() {
  fileInput.value?.click();
}

function onFile(event: Event) {
  const target = event.target as HTMLInputElement;
  const file = target.files?.[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const buf = new Uint8Array(reader.result as ArrayBuffer);
    emitBytes(buf);
  };
  reader.readAsArrayBuffer(file);
  // Reset so the same file can be re-selected next click.
  target.value = '';
}

function download() {
  if (bytes.value.length === 0) return;
  // Copy into a fresh Uint8Array<ArrayBuffer> — `bytes.value` is
  // typed as `Uint8Array<ArrayBufferLike>` (the buffer could in
  // theory be a SharedArrayBuffer), which strict lib.dom refuses
  // to widen to BlobPart. The copy pins the backing buffer to a
  // plain ArrayBuffer.
  const copy = new Uint8Array(bytes.value);
  const blob = new Blob([copy], { type: 'application/octet-stream' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'tuple-field.bin';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
</script>

<template>
  <div class="dx-bf">
    <div class="dx-bf__toolbar">
      <SelectButton
        v-model="view"
        :options="VIEW_OPTIONS"
        option-label="label"
        option-value="value"
        option-disabled="disabled"
        size="small"
      />
      <Tag :value="sizeLabel" severity="secondary" />
      <div class="dx-bf__spacer" />
      <Button
        icon="pi pi-download"
        size="small"
        severity="secondary"
        text
        label="Download"
        :disabled="bytes.length === 0"
        @click="download"
      />
      <Button
        v-if="!readonly"
        icon="pi pi-upload"
        size="small"
        severity="secondary"
        text
        label="Upload"
        :disabled="disabled"
        @click="triggerUpload"
      />
      <input ref="fileInput" type="file" class="dx-bf__hidden-file" @change="onFile" />
    </div>

    <Message v-if="editError" severity="error" :closable="false">
      {{ editError }}
    </Message>

    <div v-if="view === 'hex'" class="dx-bf__hex">
      <p v-if="hexRows.length === 0" class="dx-bf__empty">(empty)</p>
      <pre v-else><span
        v-for="row in hexRows"
        :key="row.offset"
        class="dx-bf__hex-row"
      ><span class="dx-bf__hex-offset">{{ row.offset }}</span>  {{ row.bytes }}  <span class="dx-bf__hex-ascii">{{ row.ascii }}</span>
</span></pre>
    </div>

    <Textarea
      v-else-if="view === 'base64'"
      :model-value="base64"
      :disabled="disabled"
      :readonly="readonly"
      rows="3"
      autocomplete="off"
      spellcheck="false"
      class="dx-bf__textarea"
      @update:model-value="onBase64Input"
    />

    <!-- The UTF-8 tab is only offered when the bytes decode as UTF-8
         (see VIEW_OPTIONS), so reaching this branch always means a
         valid decode — no "(invalid)" fallback needed. -->
    <Textarea
      v-else-if="view === 'utf8'"
      :model-value="utf8Decoded ?? ''"
      :disabled="disabled"
      :readonly="readonly"
      rows="3"
      autocomplete="off"
      spellcheck="false"
      class="dx-bf__textarea"
      @update:model-value="onUtf8Input"
    />
  </div>
</template>

<style scoped>
.dx-bf {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.dx-bf__toolbar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.dx-bf__spacer {
  flex: 1;
}
.dx-bf__hidden-file {
  display: none;
}
.dx-bf__hex {
  font-family: var(--webui-font-mono);
  font-size: 0.78rem;
  background: var(--p-content-hover-background, rgba(255, 255, 255, 0.04));
  border-radius: var(--p-content-border-radius, 6px);
  padding: 0.5rem 0.75rem;
  max-height: 14rem;
  overflow: auto;
}
.dx-bf__hex pre {
  margin: 0;
  white-space: pre;
}
.dx-bf__hex-offset {
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.dx-bf__hex-ascii {
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.dx-bf__empty {
  margin: 0;
  font-style: italic;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.dx-bf__textarea {
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
</style>
