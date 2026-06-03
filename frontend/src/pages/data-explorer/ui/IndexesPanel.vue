<script setup lang="ts">
/**
 * DE-1.5 — collapsible "Indexes" panel rendered in the SpaceView
 * header. Lists every index of the selected space (read from the
 * existing `spaceInfo.indexes` projection) and exposes the six
 * read-only utility actions via a per-index dropdown menu:
 *   * Min / Max  — boundary tuples
 *   * Random     — one tuple via Tarantool's seeded RNG
 *   * Count      — :count over the whole index
 *   * Stat       — engine-specific stats, shown in a dialog
 *   * Bsize      — in-memory size of the index
 *
 * Mutations (create / alter / drop) ship with DE-1.4. This panel
 * intentionally stays read-only so it can land independently and
 * give operators an inspection surface today.
 */
import { ref } from 'vue';
import Panel from 'primevue/panel';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Menu from 'primevue/menu';
import Dialog from 'primevue/dialog';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface IndexInfo {
  id: number;
  name: string;
  type: string | null;
  unique: boolean | null;
  parts: string[] | null;
}

interface ActionResult {
  action: string;
  tuple: unknown[] | null;
  count: number | null;
  bytes: number | null;
  stat: Record<string, unknown> | null;
}

const props = defineProps<{
  spaceName: string;
  indexes: IndexInfo[];
}>();

const Q_ACTION = /* GraphQL */ `
  query IndexAction($space: String!, $index: String!, $action: IndexActionKind!) {
    indexAction(space: $space, index: $index, action: $action) {
      action
      tuple
      count
      bytes
      stat
    }
  }
`;

const collapsed = ref(true);
const error = ref<string | null>(null);
// Per-index ephemeral result, keyed by index name. The Menu lives
// in a single instance and pops over whichever row the operator
// clicked; the result chip below the same row stores the last
// action's output so multiple rows can show their own value.
const results = ref<Record<string, ActionResult | null>>({});
const loadingFor = ref<string | null>(null);

const menuRef = ref<InstanceType<typeof Menu> | null>(null);
const menuTargetIndex = ref<string | null>(null);

// Stat dialog state — the stat payload is a nested object, more
// readable in a wider modal than inline below a 8rem-tall row.
const statDialogOpen = ref(false);
const statDialogIndex = ref<string | null>(null);

const ACTIONS: { label: string; key: string; icon: string }[] = [
  { label: 'Min', key: 'MIN', icon: 'pi pi-arrow-down' },
  { label: 'Max', key: 'MAX', icon: 'pi pi-arrow-up' },
  { label: 'Random', key: 'RANDOM', icon: 'pi pi-refresh' },
  { label: 'Count', key: 'COUNT', icon: 'pi pi-hashtag' },
  { label: 'Stat', key: 'STAT', icon: 'pi pi-chart-pie' },
  { label: 'Bsize', key: 'BSIZE', icon: 'pi pi-database' },
];

function openMenu(event: Event, indexName: string) {
  menuTargetIndex.value = indexName;
  menuRef.value?.toggle(event);
}

async function runAction(action: string) {
  const idx = menuTargetIndex.value;
  if (!idx) return;
  loadingFor.value = idx;
  error.value = null;
  const res = await getClient()
    .query(
      Q_ACTION,
      {
        space: props.spaceName,
        index: idx,
        // graphql-server in this project validates enum variables
        // against `.value`, not the enum name. The IndexActionKind
        // schema maps MIN → 'min', COUNT → 'count', etc. — sending
        // the upper name crashes pre-resolver. Same trick as
        // `DataExplorer.vue:loadTuples` for the FilterOp enum.
        action: action.toLowerCase(),
      },
      { requestPolicy: 'network-only' },
    )
    .toPromise();
  loadingFor.value = null;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  const payload = (res.data?.indexAction ?? null) as ActionResult | null;
  results.value = { ...results.value, [idx]: payload };
  if (payload?.action === 'stat') {
    statDialogIndex.value = idx;
    statDialogOpen.value = true;
  }
}

function clearResult(name: string) {
  results.value = { ...results.value, [name]: null };
}

function renderTuple(t: unknown[]): string {
  return JSON.stringify(t);
}

function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function statForDialog(): string {
  if (!statDialogIndex.value) return '';
  const r = results.value[statDialogIndex.value];
  if (!r || !r.stat) return '(empty — engine has no per-index stats)';
  return JSON.stringify(r.stat, null, 2);
}
</script>

<template>
  <Panel toggleable :collapsed="collapsed" @update:collapsed="collapsed = $event">
    <template #header>
      <span class="webui-idx__title">
        <i class="pi pi-key" />
        <span>Indexes</span>
        <Tag :value="`${indexes.length}`" severity="info" />
      </span>
    </template>

    <Message v-if="error" severity="error" :closable="true" @close="error = null">
      {{ error }}
    </Message>

    <div v-if="indexes.length === 0" class="webui-idx__empty">No indexes on this space.</div>

    <ul v-else class="webui-idx__list">
      <li v-for="idx in indexes" :key="idx.id" class="webui-idx__item">
        <div class="webui-idx__row">
          <code class="webui-idx__name">{{ idx.name }}</code>
          <Tag v-if="idx.type" :value="idx.type" severity="secondary" />
          <Tag
            v-if="idx.unique != null"
            :value="idx.unique ? 'unique' : 'non-unique'"
            :severity="idx.unique ? 'success' : 'secondary'"
          />
          <span class="webui-idx__parts">
            <Tag v-for="part in idx.parts ?? []" :key="part" :value="part" severity="secondary" />
          </span>
          <div class="webui-idx__spacer" />
          <Button
            icon="pi pi-wrench"
            label="Tools"
            size="small"
            severity="secondary"
            text
            :loading="loadingFor === idx.name"
            @click="openMenu($event, idx.name)"
          />
        </div>
        <div v-if="results[idx.name]" class="webui-idx__result">
          <Tag :value="results[idx.name]!.action" severity="info" />
          <code v-if="results[idx.name]!.tuple !== null">
            {{ renderTuple(results[idx.name]!.tuple!) }}
          </code>
          <code v-else-if="results[idx.name]!.count !== null">
            count = {{ results[idx.name]!.count!.toLocaleString() }}
          </code>
          <code v-else-if="results[idx.name]!.bytes !== null">
            bsize = {{ humanBytes(results[idx.name]!.bytes!) }}
          </code>
          <code v-else-if="results[idx.name]!.stat !== null"> stat shown in dialog </code>
          <code v-else>—</code>
          <Button
            icon="pi pi-times"
            severity="secondary"
            text
            size="small"
            aria-label="Clear result"
            @click="clearResult(idx.name)"
          />
        </div>
      </li>
    </ul>

    <Menu
      ref="menuRef"
      :model="
        ACTIONS.map((a) => ({
          label: a.label,
          icon: a.icon,
          command: () => runAction(a.key),
        }))
      "
      :popup="true"
    />

    <Dialog
      v-model:visible="statDialogOpen"
      modal
      :header="`Stat: ${statDialogIndex ?? ''}`"
      :style="{ width: '32rem' }"
    >
      <pre class="webui-idx__stat-dump">{{ statForDialog() }}</pre>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="statDialogOpen = false" />
      </template>
    </Dialog>
  </Panel>
</template>

<style scoped>
.webui-idx__title {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-weight: 600;
}
.webui-idx__title i {
  color: var(--p-primary-color, var(--webui-accent));
}
.webui-idx__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.webui-idx__item {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--p-content-border-color, var(--webui-border));
  border-radius: var(--p-content-border-radius, 6px);
  background: var(--p-content-background, var(--webui-bg-elevated));
}
.webui-idx__row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-idx__name {
  font-family: var(--webui-font-mono);
  font-weight: 600;
}
.webui-idx__parts {
  display: inline-flex;
  gap: 0.25rem;
  flex-wrap: wrap;
}
.webui-idx__spacer {
  flex: 1;
}
.webui-idx__result {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.85rem;
}
.webui-idx__result code {
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
.webui-idx__empty {
  font-size: 0.85rem;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-idx__stat-dump {
  font-family: var(--webui-font-mono);
  font-size: 0.78rem;
  margin: 0;
  padding: 0.75rem;
  background: var(--p-content-hover-background, rgba(255, 255, 255, 0.04));
  border-radius: var(--p-content-border-radius, 6px);
  white-space: pre-wrap;
  max-height: 24rem;
  overflow: auto;
}
</style>
