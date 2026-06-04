<script setup lang="ts">
// Sticky timeline panel: configHistory revisions next to the YAML editor.
//
// Backend: /history/<rev> keys in etcd (own-storage, NOT mod_revision
// history) — cap MAX_HISTORY=200, deterministic oldest_available_revision.
// On miss the parent shows REVISION_NOT_FOUND inline; this panel only
// surfaces the timeline itself.

import { computed, onMounted, ref, watch } from 'vue';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface RevisionInfo {
  revision: number;
  ts: number | null;
  user: string | null;
  hash: string | null;
  size: number | null;
  action: string | null;
}

interface HistoryPage {
  revisions: RevisionInfo[];
  oldest_available_revision: number | null;
  more: boolean;
}

const props = defineProps<{
  // Current cluster revision (from the parent's config query). When set
  // we mark the matching row as "active" so the operator sees where the
  // editor body comes from.
  currentRevision?: number | null;
}>();

const emit = defineEmits<{
  (e: 'select-revision', revision: number): void;
  (e: 'request-diff', revision: number, against: 'prev' | 'current'): void;
  (e: 'request-rollback', revision: number): void;
  (e: 'request-force-apply', revision: number): void;
}>();

const Q_HISTORY = /* GraphQL */ `
  query CfgHistory($limit: Int) {
    configHistory(limit: $limit) {
      revisions {
        revision
        ts
        user
        hash
        size
        action
      }
      oldest_available_revision
      more
    }
  }
`;

const loading = ref(false);
const error = ref<string | null>(null);
const page = ref<HistoryPage>({
  revisions: [],
  oldest_available_revision: null,
  more: false,
});

const loadHistory = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient()
    .query<{ configHistory: HistoryPage }>(
      Q_HISTORY,
      { limit: 50 },
      {
        requestPolicy: 'network-only',
      },
    )
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loading.value = false;
    return;
  }
  page.value = res.data?.configHistory ?? {
    revisions: [],
    oldest_available_revision: null,
    more: false,
  };
  loading.value = false;
};

// Re-fetch when the parent commits a new revision; the parent passes
// currentRevision so we react to commits/rollbacks transparently.
watch(
  () => props.currentRevision,
  (next, prev) => {
    if (next !== prev) void loadHistory();
  },
);

onMounted(loadHistory);

defineExpose({ refresh: loadHistory });

const formatTs = (ts: number | null): string => {
  if (ts == null) return '—';
  return new Date(ts * 1000).toLocaleString();
};

const formatSize = (n: number | null): string => {
  if (n == null) return '—';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
};

// Plan asked for both "Diff vs current" and "Diff vs prev" buttons —
// pick the previous revision in the timeline as the diff target for
// the latter. Returns null when this is the oldest row available.
const previousRevision = (rev: number): number | null => {
  const sorted = [...page.value.revisions].sort((a, b) => a.revision - b.revision);
  let candidate: number | null = null;
  for (const r of sorted) {
    if (r.revision < rev) candidate = r.revision;
  }
  return candidate;
};

const totalShown = computed(() => page.value.revisions.length);
const oldest = computed(() => page.value.oldest_available_revision);
const hasMore = computed(() => page.value.more);
</script>

<template>
  <aside class="webui-history">
    <header class="webui-history__head">
      <h2>History</h2>
      <Button
        icon="pi pi-refresh"
        size="small"
        text
        :loading="loading"
        aria-label="Refresh history"
        @click="loadHistory"
      />
    </header>

    <Message v-if="error" severity="error" variant="simple" size="small">{{ error }}</Message>

    <Message
      v-if="!loading && totalShown === 0 && !error"
      severity="info"
      variant="simple"
      size="small"
      :closable="false"
    >
      No committed revisions yet.
    </Message>

    <ul v-if="totalShown > 0" class="webui-history__list">
      <li
        v-for="rev in page.revisions"
        :key="rev.revision"
        :class="[
          'webui-history__row',
          { 'webui-history__row--active': currentRevision === rev.revision },
        ]"
      >
        <div class="webui-history__row-head">
          <code class="webui-history__rev">#{{ rev.revision }}</code>
          <span class="webui-history__ts">{{ formatTs(rev.ts) }}</span>
        </div>
        <div class="webui-history__meta">
          <span v-if="rev.user" class="webui-history__user">{{ rev.user }}</span>
          <span v-if="rev.action" class="webui-history__action">{{ rev.action }}</span>
          <span v-if="rev.size != null" class="webui-history__size">{{
            formatSize(rev.size)
          }}</span>
          <code v-if="rev.hash" class="webui-history__hash" :title="rev.hash">
            {{ rev.hash.slice(0, 8) }}
          </code>
        </div>
        <div class="webui-history__actions">
          <Button
            size="small"
            text
            label="View"
            title="Load this revision into the editor (preview before commit)"
            @click="emit('select-revision', rev.revision)"
          />
          <Button
            size="small"
            text
            label="Diff vs current"
            :disabled="currentRevision != null && rev.revision === currentRevision"
            @click="emit('request-diff', rev.revision, 'current')"
          />
          <Button
            size="small"
            text
            label="Diff vs prev"
            :disabled="previousRevision(rev.revision) == null"
            @click="emit('request-diff', rev.revision, 'prev')"
          />
          <Button
            size="small"
            text
            severity="warn"
            label="Rollback"
            :disabled="currentRevision != null && rev.revision === currentRevision"
            @click="emit('request-rollback', rev.revision)"
          />
          <Button
            size="small"
            text
            severity="danger"
            label="Force apply"
            title="Roll back to this revision AND fan-out config:reload on every peer (covers stragglers that missed a previous commit)."
            @click="emit('request-force-apply', rev.revision)"
          />
        </div>
      </li>
    </ul>

    <footer class="webui-history__foot">
      <Message v-if="totalShown > 0" size="small" severity="secondary" variant="simple">
        Showing {{ totalShown }} revision<span v-if="totalShown !== 1">s</span>
        <span v-if="hasMore"> (more available — refine via API)</span>
      </Message>
      <Message v-if="oldest != null" size="small" severity="secondary" variant="simple">
        Oldest available: <code>#{{ oldest }}</code>
        <span class="webui-history__floor-hint">
          — earlier revisions aged out beyond MAX_HISTORY (200)
        </span>
      </Message>
    </footer>
  </aside>
</template>

<style scoped>
.webui-history {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: var(--webui-radius, 6px);
  background: var(--webui-bg-elevated, #161a23);
  padding: 0.75rem 0.85rem;
  width: 100%;
  max-height: 70vh;
  overflow-y: auto;
}
.webui-history__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid var(--webui-border, #2a2f3a);
  padding-bottom: 0.5rem;
}
.webui-history__head h2 {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
}
.webui-history__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.webui-history__row {
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: var(--webui-radius, 6px);
  padding: 0.45rem 0.6rem;
  background: var(--webui-bg, #11141d);
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}
.webui-history__row--active {
  border-color: var(--webui-accent, #4ea8de);
  box-shadow: 0 0 0 1px var(--webui-accent, #4ea8de) inset;
}
.webui-history__row-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
}
.webui-history__rev {
  font-family: var(--webui-font-mono, monospace);
  font-weight: 600;
}
.webui-history__ts {
  color: var(--webui-text-muted, #8a93a6);
  font-size: 0.78rem;
}
.webui-history__meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  font-size: 0.75rem;
  color: var(--webui-text-muted, #8a93a6);
}
.webui-history__user {
  color: var(--webui-accent, #4ea8de);
}
.webui-history__action {
  padding: 0 0.35rem;
  border: 1px solid var(--webui-border, #2a2f3a);
  border-radius: 999px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.webui-history__hash {
  font-family: var(--webui-font-mono, monospace);
}
.webui-history__actions {
  display: flex;
  gap: 0.25rem;
  flex-wrap: wrap;
}
.webui-history__foot {
  border-top: 1px solid var(--webui-border, #2a2f3a);
  padding-top: 0.5rem;
  color: var(--webui-text-muted, #8a93a6);
  font-size: 0.78rem;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.webui-history__floor-hint {
  opacity: 0.8;
}
</style>
