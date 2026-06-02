<script setup lang="ts">
import { storeToRefs } from 'pinia';
import Dropdown from 'primevue/dropdown';
import Button from 'primevue/button';

import { useIssueStore, IssueRow } from '@/entities/issue';

const store = useIssueStore();
const { items, total, summary, fetching, filters } = storeToRefs(store);

const severityOptions = [
  { value: null, label: 'all' },
  { value: 'CRITICAL', label: 'critical' },
  { value: 'WARNING', label: 'warning' },
];

const scopeOptions = [
  { value: null, label: 'all' },
  { value: 'CLUSTER', label: 'cluster' },
  { value: 'REPLICASET', label: 'replicaset' },
  { value: 'INSTANCE', label: 'instance' },
];

const categoryOptions = [
  { value: null, label: 'all' },
  { value: 'REPLICATION', label: 'replication' },
  { value: 'MEMORY', label: 'memory' },
  { value: 'CLOCK', label: 'clock' },
  { value: 'CONFIG', label: 'config' },
];
</script>

<template>
  <section class="webui-issues-page">
    <header class="webui-issues-page__head">
      <h1 class="webui-issues-page__title">Issues</h1>
      <div class="webui-issues-page__summary">
        <span class="webui-issues-page__chip webui-issues-page__chip--critical">
          critical {{ summary.critical }}
        </span>
        <span class="webui-issues-page__chip webui-issues-page__chip--warning">
          warning {{ summary.warning }}
        </span>
        <span class="webui-issues-page__chip">total {{ summary.total }}</span>
      </div>
    </header>

    <fieldset class="webui-issues-page__filters">
      <label>
        <span class="webui-issues-page__filter-label">Severity</span>
        <Dropdown
          v-model="filters.severity"
          :options="severityOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          class="webui-issues-page__select"
        />
      </label>
      <label>
        <span class="webui-issues-page__filter-label">Scope</span>
        <Dropdown
          v-model="filters.scope"
          :options="scopeOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          class="webui-issues-page__select"
        />
      </label>
      <label>
        <span class="webui-issues-page__filter-label">Category</span>
        <Dropdown
          v-model="filters.category"
          :options="categoryOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          class="webui-issues-page__select"
        />
      </label>
      <Button
        type="button"
        label="Reset"
        severity="secondary"
        outlined
        size="small"
        class="webui-issues-page__reset"
        @click="store.resetFilters"
      />
    </fieldset>

    <p v-if="fetching && items.length === 0" class="webui-issues-page__empty">Loading…</p>
    <p v-else-if="items.length === 0" class="webui-issues-page__empty">
      No issues match the current filter.
    </p>
    <div v-else class="webui-issues-page__list">
      <IssueRow v-for="issue in items" :key="issue.id" :issue="issue" />
    </div>

    <footer v-if="items.length > 0" class="webui-issues-page__footer">
      Showing {{ items.length }} of {{ total }}.
    </footer>
  </section>
</template>

<style scoped>
.webui-issues-page {
  padding: 1rem 1.5rem 2rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.webui-issues-page__head {
  display: flex;
  align-items: center;
  gap: 1rem;
  flex-wrap: wrap;
}

.webui-issues-page__title {
  margin: 0;
  font-size: 1.4rem;
}

.webui-issues-page__summary {
  display: flex;
  gap: 0.4rem;
  margin-left: auto;
}

.webui-issues-page__chip {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  padding: 0.15rem 0.55rem;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.05);
  color: var(--webui-text-muted);
  font-weight: 700;
}

.webui-issues-page__chip--critical {
  background: rgba(248, 81, 73, 0.18);
  color: var(--webui-danger);
}

.webui-issues-page__chip--warning {
  background: rgba(210, 153, 34, 0.18);
  color: var(--webui-warning);
}

.webui-issues-page__filters {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
  padding: 0.75rem 1rem;
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
  font-size: 0.85rem;
}

.webui-issues-page__filters label {
  display: inline-flex;
  flex-direction: column;
  gap: 0.25rem;
}

.webui-issues-page__filter-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--webui-text-muted);
}

.webui-issues-page__select {
  min-width: 9rem;
}

.webui-issues-page__reset {
  align-self: flex-end;
}

.webui-issues-page__list {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
}

.webui-issues-page__empty {
  color: var(--webui-text-muted);
  text-align: center;
  padding: 2rem;
  border: 1px dashed var(--webui-border);
  border-radius: var(--webui-radius);
}

.webui-issues-page__footer {
  text-align: right;
  color: var(--webui-text-muted);
  font-size: 0.8rem;
}
</style>
