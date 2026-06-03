<!--
  Modal for creating / editing one tuple.

  Two modes share the same form:
    * `create`  → tupleInsert; every field starts empty.
    * `edit`    → tupleReplace; fields initialised from the row.

  The form does not pretend to know every Tarantool type — every
  field is a textarea / input pair and we parse JSON on submit.
  Boolean and numeric coercion happens server-side (data_mutations
  resolver), so the SPA only needs to deliver something the JSON
  scalar can serialize.
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import Dialog from 'primevue/dialog';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import BinaryField from './BinaryField.vue';
import { type BinaryEnvelope } from './binary-helpers';
import Textarea from 'primevue/textarea';
import Checkbox from 'primevue/checkbox';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface FieldFormat {
  name: string;
  type: string;
  is_nullable: boolean | null;
  collation: string | null;
}
interface IndexInfo {
  id: number;
  parts: string[] | null;
}
interface SpaceInfo {
  id: number;
  name: string;
  format: FieldFormat[] | null;
  indexes: IndexInfo[] | null;
}

interface Props {
  visible: boolean;
  space: SpaceInfo;
  mode: 'create' | 'edit';
  initialFields: unknown[] | null;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  'update:visible': [value: boolean];
  saved: [];
}>();

const INSERT_M = /* GraphQL */ `
  mutation DxInsert($space: String!, $fields: [Json]!) {
    tupleInsert(space: $space, fields: $fields) {
      ok
      after
      forwarded
      leader
    }
  }
`;

const REPLACE_M = /* GraphQL */ `
  mutation DxReplace($space: String!, $fields: [Json]!) {
    tupleReplace(space: $space, fields: $fields) {
      ok
      before
      after
      forwarded
      leader
    }
  }
`;

// One row of state per field. We keep the value as a string in
// `raw` so the operator can type freely; on submit we JSON-parse
// each non-null field. Tabular layout under the hood, no PrimeVue
// FormKit dependency.
interface FieldState {
  name: string;
  type: string;
  is_nullable: boolean;
  raw: string;
  is_null: boolean;
  // True for `varbinary` fields AND for `string` fields whose
  // initial value arrived as the `_binary_base64` envelope (the
  // backend wraps non-UTF-8 string bytes that way — see
  // `data_explorer/types.lua:99`). When set, the row renders
  // through BinaryField instead of InputText and `binary` carries
  // the canonical envelope.
  is_binary: boolean;
  binary: BinaryEnvelope;
}

function isBinaryEnvelope(v: unknown): v is BinaryEnvelope {
  return (
    typeof v === 'object' &&
    v !== null &&
    typeof (v as { _binary_base64?: unknown })._binary_base64 === 'string'
  );
}

const rows = ref<FieldState[]>([]);
const submitting = ref(false);
const error = ref<string | null>(null);

watch(
  () => [props.visible, props.space.id, props.mode],
  () => {
    if (!props.visible) return;
    rebuildRows();
    error.value = null;
  },
  { immediate: true },
);

function rebuildRows() {
  const fmt = props.space.format ?? [];
  const isCreate = props.mode === 'create';
  rows.value = fmt.map((f, i) => {
    const initial = isCreate ? undefined : props.initialFields?.[i];
    const hasExistingValue = !isCreate && initial !== undefined && initial !== null;

    // Binary detection. A `varbinary` field always renders as binary;
    // a `string` field renders as binary when the wire shape is
    // already the envelope (i.e. the stored bytes are not UTF-8 and
    // the backend escaped them). Otherwise the field stays a regular
    // InputText so plain-text strings keep their usual UX.
    const initialIsEnvelope = isBinaryEnvelope(initial);
    const isBinary = f.type === 'varbinary' || initialIsEnvelope;
    let binary: BinaryEnvelope = { _binary_base64: '' };
    if (isBinary && initialIsEnvelope) {
      binary = initial as BinaryEnvelope;
    }

    let raw = '';
    if (!isBinary && hasExistingValue) {
      if (typeof initial === 'string') raw = initial;
      else raw = JSON.stringify(initial);
    }
    // is_null defaults to `true` only when EDITING a nullable field
    // whose stored value really is null. In CREATE mode every input
    // starts editable; the operator opts into NULL by toggling the
    // checkbox (only available on nullable fields).
    const isNullableNullInEdit =
      !isCreate && f.is_nullable === true && (initial === null || initial === undefined);
    return {
      name: f.name,
      type: f.type,
      is_nullable: f.is_nullable === true,
      raw,
      is_null: isNullableNullInEdit,
      is_binary: isBinary,
      binary,
    };
  });
}

const title = computed(() =>
  props.mode === 'create' ? 'New tuple' : `Edit tuple — ${props.space.name}`,
);

function parseValue(row: FieldState): unknown {
  if (row.is_null) return null;
  // Binary fields ship the envelope object straight through. The
  // backend `coerce_field` (data_explorer/types.lua) accepts
  // `{_binary_base64: ...}` and decodes it server-side.
  if (row.is_binary) return row.binary;
  // Numeric types: try Number() first so the operator does not
  // have to wrap small ints in quotes.
  if (['unsigned', 'integer', 'number', 'double', 'float'].includes(row.type)) {
    const n = Number(row.raw);
    return Number.isFinite(n) ? n : row.raw;
  }
  if (row.type === 'boolean') {
    return row.raw === 'true' || row.raw === '1';
  }
  // Map / array: explicit JSON. Anything else passes through as a
  // string and the server's coercion layer takes over.
  if (row.type === 'map' || row.type === 'array' || row.type === 'any') {
    if (row.raw.trim() === '') return null;
    try {
      return JSON.parse(row.raw);
    } catch {
      return row.raw;
    }
  }
  return row.raw;
}

async function submit() {
  submitting.value = true;
  error.value = null;
  const fields = rows.value.map(parseValue);
  const mutation = props.mode === 'create' ? INSERT_M : REPLACE_M;
  const res = await getClient().mutation(mutation, { space: props.space.name, fields }).toPromise();
  submitting.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  // GraphQL errors land in res.error already; if a typed error
  // makes it to .data we surface the message and stay open so the
  // operator can correct the value.
  const payload =
    (res.data as { tupleInsert?: { ok: boolean }; tupleReplace?: { ok: boolean } } | undefined) ??
    {};
  const result = payload.tupleInsert ?? payload.tupleReplace;
  if (result === undefined || result.ok !== true) {
    error.value = 'Mutation rejected by server (no `ok: true`).';
    return;
  }
  emit('saved');
}

function close() {
  emit('update:visible', false);
}
</script>

<template>
  <Dialog
    :visible="visible"
    modal
    :header="title"
    :style="{ width: '40rem' }"
    @update:visible="emit('update:visible', $event)"
  >
    <div v-if="error" class="dx-tf__error">
      <Message severity="error" :closable="false">{{ error }}</Message>
    </div>

    <div class="dx-tf__rows">
      <div v-for="(r, i) in rows" :key="i" class="dx-tf__row">
        <label class="dx-tf__label">
          <span>{{ r.name }}</span>
          <small>{{ r.type }}<span v-if="r.is_nullable"> · nullable</span></small>
        </label>
        <div class="dx-tf__value">
          <BinaryField
            v-if="r.is_binary"
            v-model="r.binary"
            :disabled="r.is_null"
          />
          <Textarea
            v-else-if="r.type === 'map' || r.type === 'array' || r.type === 'any'"
            v-model="r.raw"
            :disabled="r.is_null"
            rows="2"
            placeholder='{"k": "v"} or [1, 2, 3]'
          />
          <InputText v-else v-model="r.raw" :disabled="r.is_null" />
          <label v-if="r.is_nullable" class="dx-tf__null-toggle">
            <Checkbox v-model="r.is_null" binary />
            <span>null</span>
          </label>
        </div>
      </div>
    </div>

    <template #footer>
      <Button label="Cancel" severity="secondary" text @click="close" />
      <Button
        :label="mode === 'create' ? 'Insert' : 'Replace'"
        :icon="mode === 'create' ? 'pi pi-plus' : 'pi pi-save'"
        :loading="submitting"
        severity="success"
        @click="submit"
      />
    </template>
  </Dialog>
</template>

<style scoped>
.dx-tf__rows {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.dx-tf__row {
  display: grid;
  grid-template-columns: 10rem 1fr;
  gap: 0.5rem;
  align-items: start;
}
.dx-tf__label {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  padding-top: 0.3rem;
}
.dx-tf__label small {
  color: var(--webui-text-muted);
  font-size: 0.7rem;
}
.dx-tf__value {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.dx-tf__value :deep(.p-inputtext),
.dx-tf__value :deep(.p-textarea) {
  flex: 1 1 auto;
}
.dx-tf__null-toggle {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.75rem;
  color: var(--webui-text-muted);
}
.dx-tf__error {
  margin-bottom: 0.5rem;
}
</style>
