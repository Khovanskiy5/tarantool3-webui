<script setup lang="ts">
/**
 * DE-1.3 — collapsible "Sequence" panel rendered in the SpaceView
 * header when the selected space has an attached sequence. Reads
 * `sequenceInfo` lazily on first expand and offers the operator
 * the two most-asked actions (Set new value, Reset to start) plus
 * the rarer Alter / Drop.
 *
 * Attaching a sequence to a fresh space is intentionally NOT in
 * this panel — that needs `alterIndex` which lands in DE-1.4. Same
 * with switching the bound index. Once that mutation exists this
 * panel will grow an "Attach to primary key" button alongside.
 */
import { ref, watch } from 'vue';
import Panel from 'primevue/panel';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Dialog from 'primevue/dialog';
import InputText from 'primevue/inputtext';
import Fluid from 'primevue/fluid';
import Message from 'primevue/message';
import ToggleSwitch from 'primevue/toggleswitch';

import { getClient } from '@/shared/api/graphql';
import { DestructiveActionDialog } from '@/shared/ui/destructive-action-dialog';

interface SequenceAttachment {
  space: string;
  field: number | null;
  path: string | null;
}

interface SequenceInfo {
  id: number;
  name: string;
  step: number;
  min: number;
  max: number;
  start: number;
  cache: number;
  cycle: boolean;
  current: number | null;
  attached_to: SequenceAttachment[];
}

const props = defineProps<{
  /** Attached sequence name resolved from `spaceInfo`. Null → no panel. */
  sequenceName: string | null;
}>();

const Q_INFO = /* GraphQL */ `
  query SequenceInfo($name: String!) {
    sequenceInfo(name: $name) {
      id name step min max start cache cycle current
      attached_to { space field path }
    }
  }
`;

const M_SET = /* GraphQL */ `
  mutation SeqSet($name: String!, $value: Long!) {
    sequenceSet(name: $name, value: $value) { ok name current }
  }
`;

const M_RESET = /* GraphQL */ `
  mutation SeqReset($name: String!) {
    sequenceReset(name: $name) { ok name current }
  }
`;

const M_ALTER = /* GraphQL */ `
  mutation SeqAlter($input: SequenceAlterInput!) {
    sequenceAlter(input: $input) { ok name }
  }
`;

const M_DROP = /* GraphQL */ `
  mutation SeqDrop($name: String!) {
    sequenceDrop(name: $name) { ok name }
  }
`;

const info = ref<SequenceInfo | null>(null);
const loading = ref(false);
const error = ref<string | null>(null);
const collapsed = ref(true);

// Set dialog
const setDialogOpen = ref(false);
const setValueInput = ref<string>('');
const setPending = ref(false);

// Alter dialog
const alterDialogOpen = ref(false);
const alterPending = ref(false);
const alterStep = ref<string>('');
const alterMin = ref<string>('');
const alterMax = ref<string>('');
const alterStart = ref<string>('');
const alterCache = ref<string>('');
const alterCycle = ref<boolean>(false);

// Drop confirmation
const dropConfirmOpen = ref(false);
const dropPending = ref(false);

async function load() {
  if (!props.sequenceName) return;
  loading.value = true;
  error.value = null;
  const res = await getClient()
    .query(Q_INFO, { name: props.sequenceName }, { requestPolicy: 'network-only' })
    .toPromise();
  loading.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  info.value = res.data?.sequenceInfo ?? null;
}

watch(
  () => [props.sequenceName, collapsed.value] as const,
  ([name, isCollapsed]) => {
    if (!name || isCollapsed) return;
    if (info.value && info.value.name === name) return;
    load();
  },
);

function openSet() {
  setValueInput.value = info.value?.current != null ? String(info.value.current) : '0';
  setDialogOpen.value = true;
}

async function confirmSet() {
  if (!info.value) return;
  const v = Number(setValueInput.value);
  if (!Number.isFinite(v) || !Number.isInteger(v)) {
    error.value = 'Value must be an integer';
    return;
  }
  setPending.value = true;
  const res = await getClient()
    .mutation(M_SET, { name: info.value.name, value: v })
    .toPromise();
  setPending.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  setDialogOpen.value = false;
  await load();
}

async function reset() {
  if (!info.value) return;
  const res = await getClient()
    .mutation(M_RESET, { name: info.value.name })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  await load();
}

function openAlter() {
  if (!info.value) return;
  alterStep.value = String(info.value.step);
  alterMin.value = String(info.value.min);
  alterMax.value = String(info.value.max);
  alterStart.value = String(info.value.start);
  alterCache.value = String(info.value.cache);
  alterCycle.value = info.value.cycle;
  alterDialogOpen.value = true;
}

function parseLong(s: string, fallback: number): number | undefined {
  if (s.trim() === '') return undefined;
  const v = Number(s);
  if (!Number.isFinite(v) || !Number.isInteger(v)) return fallback;
  return v;
}

async function confirmAlter() {
  if (!info.value) return;
  alterPending.value = true;
  const input = {
    name: info.value.name,
    step: parseLong(alterStep.value, info.value.step),
    min: parseLong(alterMin.value, info.value.min),
    max: parseLong(alterMax.value, info.value.max),
    start: parseLong(alterStart.value, info.value.start),
    cache: parseLong(alterCache.value, info.value.cache),
    cycle: alterCycle.value,
  };
  const res = await getClient().mutation(M_ALTER, { input }).toPromise();
  alterPending.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  alterDialogOpen.value = false;
  await load();
}

function openDropConfirm() {
  dropConfirmOpen.value = true;
}

async function confirmDrop() {
  if (!info.value) return;
  dropPending.value = true;
  const res = await getClient()
    .mutation(M_DROP, { name: info.value.name })
    .toPromise();
  dropPending.value = false;
  if (res.error) {
    error.value = res.error.message;
    dropConfirmOpen.value = false;
    return;
  }
  dropConfirmOpen.value = false;
  // Drop deleted the sequence — the parent SpaceView will refetch
  // and remove the panel on the next render. Clear local state so
  // nothing dangles.
  info.value = null;
  await load();
}
</script>

<template>
  <Panel
    v-if="sequenceName"
    toggleable
    :collapsed="collapsed"
    @update:collapsed="collapsed = $event"
  >
    <template #header>
      <span class="webui-seq__title">
        <i class="pi pi-sort-numeric-up" />
        <span>Sequence</span>
        <Tag :value="sequenceName" severity="info" />
        <Tag
          v-if="info && info.current !== null"
          :value="`current: ${info.current}`"
          severity="secondary"
        />
        <Tag
          v-else-if="info && info.current === null"
          value="unused"
          severity="secondary"
        />
      </span>
    </template>

    <Message v-if="error" severity="error" :closable="true" @close="error = null">
      {{ error }}
    </Message>

    <div v-if="loading && !info" class="webui-seq__empty">Loading…</div>

    <div v-else-if="info" class="webui-seq__body">
      <dl class="webui-seq__grid">
        <div class="webui-seq__item">
          <dt>current</dt>
          <dd>{{ info.current ?? '—' }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>start</dt>
          <dd>{{ info.start }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>step</dt>
          <dd>{{ info.step }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>min</dt>
          <dd>{{ info.min }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>max</dt>
          <dd>{{ info.max }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>cache</dt>
          <dd>{{ info.cache }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>cycle</dt>
          <dd>{{ info.cycle ? 'yes' : 'no' }}</dd>
        </div>
        <div class="webui-seq__item">
          <dt>id</dt>
          <dd>{{ info.id }}</dd>
        </div>
      </dl>

      <div v-if="info.attached_to.length > 1" class="webui-seq__attached">
        <Message severity="info" :closable="false">
          <strong>Shared sequence.</strong> This sequence drives
          {{ info.attached_to.length }} indexes —
          {{ info.attached_to.map((a) => a.space).join(', ') }}. Drop
          requires detaching from every index first.
        </Message>
      </div>

      <div class="webui-seq__actions">
        <Button icon="pi pi-pencil" size="small" label="Set value…" @click="openSet" />
        <Button
          icon="pi pi-replay"
          size="small"
          severity="secondary"
          label="Reset"
          @click="reset"
        />
        <Button
          icon="pi pi-cog"
          size="small"
          severity="secondary"
          text
          label="Alter…"
          @click="openAlter"
        />
        <Button
          icon="pi pi-trash"
          size="small"
          severity="danger"
          text
          label="Drop"
          @click="openDropConfirm"
        />
        <Button
          icon="pi pi-refresh"
          size="small"
          severity="secondary"
          text
          label="Reload"
          :loading="loading"
          @click="load"
        />
      </div>
    </div>

    <div v-else class="webui-seq__empty">
      Expand to load info for <code>{{ sequenceName }}</code>.
    </div>
  </Panel>

  <!-- Set value dialog -->
  <Dialog
    v-model:visible="setDialogOpen"
    modal
    header="Set sequence value"
    :style="{ width: '24rem' }"
  >
    <Fluid>
      <div class="r-field">
        <label for="seq-set-value">New value</label>
        <InputText
          id="seq-set-value"
          v-model="setValueInput"
          autofocus
          @keyup.enter="confirmSet"
        />
        <Message size="small" variant="simple">
          The next <code>:next()</code> will return <code>value + step</code>.
        </Message>
      </div>
    </Fluid>
    <template #footer>
      <Button label="Cancel" severity="secondary" text @click="setDialogOpen = false" />
      <Button label="Set" icon="pi pi-check" :loading="setPending" @click="confirmSet" />
    </template>
  </Dialog>

  <!-- Alter dialog -->
  <Dialog
    v-model:visible="alterDialogOpen"
    modal
    header="Alter sequence"
    :style="{ width: '28rem' }"
  >
    <Fluid>
      <div class="r-field">
        <label for="seq-alter-step">step</label>
        <InputText id="seq-alter-step" v-model="alterStep" />
      </div>
      <div class="r-field">
        <label for="seq-alter-min">min</label>
        <InputText id="seq-alter-min" v-model="alterMin" />
      </div>
      <div class="r-field">
        <label for="seq-alter-max">max</label>
        <InputText id="seq-alter-max" v-model="alterMax" />
      </div>
      <div class="r-field">
        <label for="seq-alter-start">start</label>
        <InputText id="seq-alter-start" v-model="alterStart" />
      </div>
      <div class="r-field">
        <label for="seq-alter-cache">cache</label>
        <InputText id="seq-alter-cache" v-model="alterCache" />
      </div>
      <div class="r-field">
        <label for="seq-alter-cycle">cycle</label>
        <ToggleSwitch v-model="alterCycle" input-id="seq-alter-cycle" />
      </div>
    </Fluid>
    <template #footer>
      <Button
        label="Cancel"
        severity="secondary"
        text
        @click="alterDialogOpen = false"
      />
      <Button
        label="Apply"
        icon="pi pi-check"
        :loading="alterPending"
        @click="confirmAlter"
      />
    </template>
  </Dialog>

  <!-- Drop confirmation -->
  <DestructiveActionDialog
    :open="dropConfirmOpen"
    title="Drop sequence"
    :description="
      'Drops sequence “' +
      (info?.name ?? '') +
      '”. Attached indexes lose their auto-increment source — Tarantool ' +
      'refuses the drop until every binding is removed via alterIndex({sequence: false}). ' +
      'This cannot be undone.'
    "
    :expected="info?.name ?? ''"
    :prompt="`Type the sequence name (${info?.name ?? ''}) to confirm:`"
    confirm-label="Drop sequence"
    :pending="dropPending"
    @cancel="dropConfirmOpen = false"
    @confirm="confirmDrop"
  />
</template>

<style scoped>
.webui-seq__title {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-weight: 600;
}
.webui-seq__title i {
  color: var(--p-primary-color, var(--webui-accent));
}
.webui-seq__body {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-seq__grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(8rem, 1fr));
  gap: 0.5rem 1rem;
  margin: 0;
}
.webui-seq__item {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}
.webui-seq__item dt {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-seq__item dd {
  margin: 0;
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
.webui-seq__attached {
  font-size: 0.85rem;
}
.webui-seq__actions {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-seq__empty {
  font-size: 0.85rem;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
</style>
