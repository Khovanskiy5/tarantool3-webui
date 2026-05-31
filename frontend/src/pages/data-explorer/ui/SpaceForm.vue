<!--
  Create / alter space modal.
  Mode "create" calls `createSpace`; mode "alter" calls `alterSpace`
  on the original name. Both surface the same set of inputs:
    * name        (alter: rename target → new_name)
    * engine      (create only — Tarantool does not allow changing
                   engine in place)
    * is_sync     (toggleable in both modes)
    * format[]    (name + type + nullable rows; add/remove dynamic)
    * primary key (comma-separated field names, create only — alter
                   would require dropping the primary index, out of
                   scope for now)
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import Dialog from 'primevue/dialog';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import Select from 'primevue/select';
import Checkbox from 'primevue/checkbox';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface FieldFormat {
  name: string;
  type: string;
  is_nullable: boolean | null;
  collation: string | null;
}
interface SpaceInfo {
  id: number;
  name: string;
  engine?: string | null;
  is_sync?: boolean | null;
  format?: FieldFormat[] | null;
}

interface Props {
  visible: boolean;
  mode: 'create' | 'alter';
  // Only used in alter mode.
  source?: SpaceInfo | null;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  'update:visible': [value: boolean];
  saved: [];
}>();

const CREATE_M = /* GraphQL */ `
  mutation DxCreateSpace($name: String!, $engine: String, $is_sync: Boolean,
                         $format: [FieldFormatInput!], $primary_key: [String!]) {
    createSpace(name: $name, engine: $engine, is_sync: $is_sync,
                format: $format, primary_key: $primary_key) {
      ok name id forwarded leader
    }
  }
`;

const ALTER_M = /* GraphQL */ `
  mutation DxAlterSpace($name: String!, $new_name: String,
                        $is_sync: Boolean, $format: [FieldFormatInput!]) {
    alterSpace(name: $name, new_name: $new_name, is_sync: $is_sync,
               format: $format) {
      ok name id
    }
  }
`;

interface FieldRow {
  name: string;
  type: string;
  is_nullable: boolean;
}

const name = ref('');
const engine = ref<'memtx' | 'vinyl'>('memtx');
const isSync = ref(false);
const primaryKey = ref<string>('');
const fields = ref<FieldRow[]>([]);
const submitting = ref(false);
const error = ref<string | null>(null);

const TYPE_OPTIONS = [
  'unsigned', 'integer', 'number', 'string', 'boolean',
  'double', 'decimal', 'uuid', 'map', 'array', 'scalar', 'any',
].map((t) => ({ label: t, value: t }));

const ENGINE_OPTIONS = [
  { label: 'memtx', value: 'memtx' },
  { label: 'vinyl', value: 'vinyl' },
];

watch(
  () => [props.visible, props.mode, props.source?.id],
  () => {
    if (!props.visible) return;
    error.value = null;
    if (props.mode === 'create') {
      name.value = '';
      engine.value = 'memtx';
      isSync.value = false;
      primaryKey.value = 'id';
      fields.value = [
        { name: 'id', type: 'unsigned', is_nullable: false },
        { name: 'value', type: 'string', is_nullable: true },
      ];
    } else if (props.source) {
      name.value = props.source.name;
      engine.value = (props.source.engine as 'memtx' | 'vinyl') ?? 'memtx';
      isSync.value = props.source.is_sync === true;
      primaryKey.value = '';
      fields.value = (props.source.format ?? []).map((f) => ({
        name: f.name,
        type: f.type,
        is_nullable: f.is_nullable === true,
      }));
    }
  },
  { immediate: true },
);

function addRow() {
  fields.value.push({ name: '', type: 'string', is_nullable: true });
}

function removeRow(i: number) {
  fields.value.splice(i, 1);
}

const title = computed(() => (props.mode === 'create'
  ? 'New space'
  : `Edit space — ${props.source?.name ?? ''}`));

async function submit() {
  submitting.value = true;
  error.value = null;
  const clean = fields.value
    .filter((f) => f.name.trim() !== '')
    .map((f) => ({ name: f.name.trim(), type: f.type, is_nullable: f.is_nullable }));
  if (clean.length === 0) {
    error.value = 'Add at least one field.';
    submitting.value = false;
    return;
  }

  let res;
  if (props.mode === 'create') {
    const pk = primaryKey.value
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    res = await getClient()
      .mutation(CREATE_M, {
        name: name.value.trim(),
        engine: engine.value,
        is_sync: isSync.value,
        format: clean,
        primary_key: pk.length > 0 ? pk : null,
      })
      .toPromise();
  } else {
    const renamed = name.value.trim() !== props.source!.name
      ? name.value.trim()
      : null;
    res = await getClient()
      .mutation(ALTER_M, {
        name: props.source!.name,
        new_name: renamed,
        is_sync: isSync.value,
        format: clean,
      })
      .toPromise();
  }
  submitting.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  const payload =
    (res.data as {
      createSpace?: { ok: boolean };
      alterSpace?: { ok: boolean };
    } | undefined) ?? {};
  const result = payload.createSpace ?? payload.alterSpace;
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
    :style="{ width: '44rem' }"
    @update:visible="emit('update:visible', $event)"
  >
    <div v-if="error" class="sf__error">
      <Message severity="error" :closable="false">{{ error }}</Message>
    </div>

    <div class="sf__row">
      <label>Name</label>
      <InputText v-model="name" :placeholder="mode === 'create' ? 'my_space' : ''" />
    </div>
    <div v-if="mode === 'create'" class="sf__row">
      <label>Engine</label>
      <Select
        v-model="engine"
        :options="ENGINE_OPTIONS"
        option-label="label"
        option-value="value"
        class="sf__select"
      />
    </div>
    <div class="sf__row">
      <label>Sync</label>
      <label class="sf__inline">
        <Checkbox v-model="isSync" binary />
        <span>is_sync (sync replication required for writes)</span>
      </label>
    </div>
    <div v-if="mode === 'create'" class="sf__row">
      <label>Primary key</label>
      <InputText
        v-model="primaryKey"
        placeholder="id"
        title="Comma-separated field names. Defaults to the first format field."
      />
    </div>

    <div class="sf__section">
      <header class="sf__section-head">
        <strong>Format</strong>
        <Button label="Add field" icon="pi pi-plus" size="small" text @click="addRow" />
      </header>
      <div v-for="(f, i) in fields" :key="i" class="sf__field">
        <InputText v-model="f.name" placeholder="field name" class="sf__field-name" />
        <Select
          v-model="f.type"
          :options="TYPE_OPTIONS"
          option-label="label"
          option-value="value"
          class="sf__field-type"
        />
        <label class="sf__inline">
          <Checkbox v-model="f.is_nullable" binary />
          <span>nullable</span>
        </label>
        <Button
          icon="pi pi-times"
          severity="danger"
          text
          size="small"
          aria-label="Remove field"
          @click="removeRow(i)"
        />
      </div>
    </div>

    <template #footer>
      <Button label="Cancel" severity="secondary" text @click="close" />
      <Button
        :label="mode === 'create' ? 'Create' : 'Apply'"
        :icon="mode === 'create' ? 'pi pi-plus' : 'pi pi-save'"
        :loading="submitting"
        severity="success"
        @click="submit"
      />
    </template>
  </Dialog>
</template>

<style scoped>
.sf__row {
  display: grid;
  grid-template-columns: 8rem 1fr;
  gap: 0.5rem;
  align-items: center;
  margin-bottom: 0.5rem;
}
.sf__row label { color: var(--webui-text-muted); font-size: 0.85rem; }
.sf__select { min-width: 12rem; }
.sf__inline {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  color: var(--webui-text-muted);
  font-size: 0.85rem;
}
.sf__section { margin-top: 1rem; }
.sf__section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.4rem;
}
.sf__field {
  display: grid;
  grid-template-columns: 1fr 12rem 8rem 2rem;
  gap: 0.5rem;
  align-items: center;
  margin-bottom: 0.3rem;
}
.sf__field-name :deep(.p-inputtext) { width: 100%; }
.sf__field-type :deep(.p-select) { width: 100%; }
.sf__error { margin-bottom: 0.5rem; }
</style>
