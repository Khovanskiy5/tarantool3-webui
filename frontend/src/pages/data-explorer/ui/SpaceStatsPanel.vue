<script setup lang="ts">
/**
 * DE-1.7 — collapsible "Stats" panel rendered in the SpaceView
 * header. Drives a single GraphQL query (`spaceStats(name)`) and
 * projects the result onto:
 *
 *   * Per-space numbers (byte_size, row_count, engine, memtx tuple
 *     breakdown when applicable).
 *   * Slab arena gauge — three PrimeVue ProgressBars driven by the
 *     ratios the resolver has already pre-parsed into floats. We
 *     intentionally surface the slab gauge inside the SpaceView,
 *     not as a separate "cluster memory" page, because operators
 *     evaluating a space's footprint almost always want to compare
 *     it against the global quota in the same view.
 *   * Memtx engine totals (data, garbage, read view).
 *   * Vinyl engine summary — collapsed in the same panel; the
 *     resolver returns nil when the space is memtx, so the section
 *     hides itself automatically.
 *
 * No mutations and no realtime polling — operators can refresh on
 * demand via the Reload button. A live refresh would push the
 * `_webui_audit` quota over for a stat that changes slowly enough
 * to read manually.
 */
import { ref, watch } from 'vue';
import Panel from 'primevue/panel';
import ProgressBar from 'primevue/progressbar';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface MemtxTuple {
  data_size: number;
  header_size: number;
  waste_size: number;
  field_map_size: number;
}

interface VinylEngine {
  memory_tuple: number;
  memory_tuple_cache: number;
  memory_level0: number;
  memory_page_index: number;
  memory_bloom_filter: number;
  disk_data_bytes: number;
  disk_data_compacted: number;
  disk_index_bytes: number;
}

interface SlabInfo {
  quota_size: number;
  quota_used: number;
  quota_used_ratio: number;
  items_size: number;
  items_used: number;
  items_used_ratio: number;
  arena_size: number;
  arena_used: number;
  arena_used_ratio: number;
}

interface MemtxData {
  total: number;
  garbage: number;
  read_view: number;
}

interface SpaceStats {
  name: string;
  id: number;
  engine: string;
  byte_size: number;
  row_count: number;
  memtx_tuple: MemtxTuple | null;
  vinyl_engine: VinylEngine | null;
  slab: SlabInfo;
  memtx_data: MemtxData;
}

const props = defineProps<{
  /** The space whose stats we display. Empty string disables the panel. */
  spaceName: string;
}>();

const Q_STATS = /* GraphQL */ `
  query SpaceStats($name: String!) {
    spaceStats(name: $name) {
      name
      id
      engine
      byte_size
      row_count
      memtx_tuple {
        data_size
        header_size
        waste_size
        field_map_size
      }
      vinyl_engine {
        memory_tuple
        memory_tuple_cache
        memory_level0
        memory_page_index
        memory_bloom_filter
        disk_data_bytes
        disk_data_compacted
        disk_index_bytes
      }
      slab {
        quota_size
        quota_used
        quota_used_ratio
        items_size
        items_used
        items_used_ratio
        arena_size
        arena_used
        arena_used_ratio
      }
      memtx_data {
        total
        garbage
        read_view
      }
    }
  }
`;

const stats = ref<SpaceStats | null>(null);
const loading = ref(false);
const error = ref<string | null>(null);
// Default-collapsed so the header stays compact; operators expand
// on demand. The panel remembers its state across renders of the
// same space because `collapsed` is local to this component.
const collapsed = ref(true);

async function load() {
  if (!props.spaceName) return;
  loading.value = true;
  error.value = null;
  const res = await getClient().query(Q_STATS, { name: props.spaceName }).toPromise();
  loading.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  stats.value = res.data?.spaceStats ?? null;
}

// Reload whenever the operator picks a different space OR the user
// expands a previously-collapsed panel for the first time. Skipping
// the fetch while collapsed keeps the query off the hot path for
// operators who never expand the panel.
watch(
  () => [props.spaceName, collapsed.value] as const,
  ([name, isCollapsed]) => {
    if (!name || isCollapsed) return;
    if (stats.value && stats.value.name === name) return;
    load();
  },
);

function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}
</script>

<template>
  <Panel toggleable :collapsed="collapsed" @update:collapsed="collapsed = $event">
    <template #header>
      <span class="webui-stats__title">
        <i class="pi pi-chart-bar" />
        <span>Stats</span>
        <Tag v-if="stats" :value="stats.engine" severity="info" />
      </span>
    </template>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <div v-if="loading && !stats" class="webui-stats__empty">Loading…</div>

    <div v-else-if="stats" class="webui-stats__body">
      <!-- Per-space block ────────────────────────────────────────── -->
      <section class="webui-stats__group">
        <h3 class="webui-stats__group-title">Space</h3>
        <dl class="webui-stats__grid">
          <div class="webui-stats__item">
            <dt>size</dt>
            <dd>{{ humanBytes(stats.byte_size) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>rows</dt>
            <dd>{{ stats.row_count.toLocaleString() }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>id</dt>
            <dd>{{ stats.id }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>engine</dt>
            <dd>{{ stats.engine }}</dd>
          </div>
        </dl>
      </section>

      <!-- Memtx tuple breakdown — only when the resolver populated it.
           Vinyl spaces return memtx_tuple=null. -->
      <section v-if="stats.memtx_tuple" class="webui-stats__group">
        <h3 class="webui-stats__group-title">Memtx tuple memory</h3>
        <dl class="webui-stats__grid">
          <div class="webui-stats__item">
            <dt>data</dt>
            <dd>{{ humanBytes(stats.memtx_tuple.data_size) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>header</dt>
            <dd>{{ humanBytes(stats.memtx_tuple.header_size) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>waste</dt>
            <dd>{{ humanBytes(stats.memtx_tuple.waste_size) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>field map</dt>
            <dd>{{ humanBytes(stats.memtx_tuple.field_map_size) }}</dd>
          </div>
        </dl>
      </section>

      <!-- Slab gauge — cluster-wide; same numbers in every space's
           panel. Surfacing them here lets the operator size a space
           against the global quota without leaving the SpaceView. -->
      <section class="webui-stats__group">
        <h3 class="webui-stats__group-title">Slab arena (cluster-wide)</h3>
        <div class="webui-stats__bars">
          <div class="webui-stats__bar">
            <span class="webui-stats__bar-label">
              quota
              <code>
                {{ humanBytes(stats.slab.quota_used) }} /
                {{ humanBytes(stats.slab.quota_size) }}
              </code>
            </span>
            <ProgressBar :value="Math.round(stats.slab.quota_used_ratio)" />
          </div>
          <div class="webui-stats__bar">
            <span class="webui-stats__bar-label">
              arena
              <code>
                {{ humanBytes(stats.slab.arena_used) }} /
                {{ humanBytes(stats.slab.arena_size) }}
              </code>
            </span>
            <ProgressBar :value="Math.round(stats.slab.arena_used_ratio)" />
          </div>
          <div class="webui-stats__bar">
            <span class="webui-stats__bar-label">
              items
              <code>
                {{ humanBytes(stats.slab.items_used) }} /
                {{ humanBytes(stats.slab.items_size) }}
              </code>
            </span>
            <ProgressBar :value="Math.round(stats.slab.items_used_ratio)" />
          </div>
        </div>
      </section>

      <!-- Engine totals. memtx is always populated; vinyl is only
           rendered when the space lives on vinyl. -->
      <section class="webui-stats__group">
        <h3 class="webui-stats__group-title">Memtx engine (cluster-wide)</h3>
        <dl class="webui-stats__grid">
          <div class="webui-stats__item">
            <dt>total</dt>
            <dd>{{ humanBytes(stats.memtx_data.total) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>garbage</dt>
            <dd>{{ humanBytes(stats.memtx_data.garbage) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>read view</dt>
            <dd>{{ humanBytes(stats.memtx_data.read_view) }}</dd>
          </div>
        </dl>
      </section>

      <section v-if="stats.vinyl_engine" class="webui-stats__group">
        <h3 class="webui-stats__group-title">Vinyl engine (cluster-wide)</h3>
        <dl class="webui-stats__grid">
          <div class="webui-stats__item">
            <dt>memory tuple</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.memory_tuple) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>tuple cache</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.memory_tuple_cache) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>level 0</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.memory_level0) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>page index</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.memory_page_index) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>bloom</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.memory_bloom_filter) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>disk data</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.disk_data_bytes) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>compacted</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.disk_data_compacted) }}</dd>
          </div>
          <div class="webui-stats__item">
            <dt>disk index</dt>
            <dd>{{ humanBytes(stats.vinyl_engine.disk_index_bytes) }}</dd>
          </div>
        </dl>
      </section>

      <div class="webui-stats__footer">
        <Button
          icon="pi pi-refresh"
          severity="secondary"
          size="small"
          text
          label="Reload"
          :loading="loading"
          @click="load"
        />
      </div>
    </div>

    <div v-else class="webui-stats__empty">
      Expand to load stats for <code>{{ spaceName }}</code
      >.
    </div>
  </Panel>
</template>

<style scoped>
/* Theme tokens: prefer PrimeVue's `--p-*` design tokens so the panel
   tracks the active theme automatically (light/dark/custom). Each
   token falls back to the project's older `--webui-*` for the
   pre-theme browsers and dev preview builds — same pattern as
   `pages/audit/ui/Audit.vue`. Component-specific surface tokens
   (`--p-panel-*`, `--p-progressbar-*`) are aliased globally in
   `app/styles/index.css` — do NOT shadow them here. */
.webui-stats__title {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-weight: 600;
}
.webui-stats__title i {
  color: var(--p-primary-color, var(--webui-accent));
}
.webui-stats__body {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-stats__group {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.webui-stats__group-title {
  margin: 0;
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-stats__grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(8rem, 1fr));
  gap: 0.5rem 1rem;
  margin: 0;
}
.webui-stats__item {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}
.webui-stats__item dt {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-stats__item dd {
  margin: 0;
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
  /* Inherit the body's `--webui-text` so values match the
     rest of the page (e.g. `.webui-dx__title`). Overriding to
     `var(--p-text-color)` here was wrong: PrimeVue's dark
     cascade maps that token to pure white, while every other
     readable block in the project uses the softer
     `#e6e6e6` from `--webui-text`. */
}
.webui-stats__bars {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.webui-stats__bar {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.webui-stats__bar-label {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  font-size: 0.78rem;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-stats__bar-label code {
  font-family: var(--webui-font-mono);
  font-size: 0.78rem;
  color: var(--p-text-color, var(--webui-text));
}
.webui-stats__footer {
  display: flex;
  justify-content: flex-end;
}
.webui-stats__empty {
  font-size: 0.85rem;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
</style>
