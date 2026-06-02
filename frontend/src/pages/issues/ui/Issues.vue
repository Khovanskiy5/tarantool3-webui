<script setup lang="ts">
import { storeToRefs } from 'pinia';
import Select from 'primevue/select';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

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
      <Tag :value="`critical ${summary.critical}`" severity="danger" />
      <Tag :value="`warning ${summary.warning}`" severity="warn" />
      <Tag :value="`total ${summary.total}`" severity="secondary" />
    </header>

    <fieldset class="webui-issues-page__filters">
      <!-- `show-clear` puts a built-in × inside each Select that
           sets the bound value to null — the canonical PrimeVue way
           to "unset" a single filter. Combined with the `{value:
           null, label: 'all'}` option already in each list, the user
           sees the same "all" placeholder whether they clicked clear
           or never picked a value. Removes the need for a separate
           Reset button that operated on every filter at once. -->
      <div class="r-field">
        <label for="issues-severity">Severity</label>
        <Select
          v-model="filters.severity"
          input-id="issues-severity"
          :options="severityOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          show-clear
        />
      </div>
      <div class="r-field">
        <label for="issues-scope">Scope</label>
        <Select
          v-model="filters.scope"
          input-id="issues-scope"
          :options="scopeOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          show-clear
        />
      </div>
      <div class="r-field">
        <label for="issues-category">Category</label>
        <Select
          v-model="filters.category"
          input-id="issues-category"
          :options="categoryOptions"
          option-label="label"
          option-value="value"
          placeholder="all"
          size="small"
          show-clear
        />
      </div>
    </fieldset>

    <!-- Single Message instance instead of two `v-if`/`v-else-if` siblings:
         every WS snapshot tick flips `fetching` between true and false,
         and two distinct elements would unmount + remount the PrimeVue
         Message each time, re-running its enter animation and causing
         the visible flicker. Keeping one element and swapping only the
         text leaves the DOM node in place. -->
    <Message v-if="items.length === 0" severity="info" :closable="false" variant="simple">
      {{ fetching ? 'Loading…' : 'No issues match the current filter.' }}
    </Message>
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
  gap: 0.75rem;
  flex-wrap: wrap;
}

.webui-issues-page__title {
  margin: 0;
  font-size: 1.4rem;
  /* Push the summary tags to the far right while keeping them packed
     next to each other with the parent's gap. */
  margin-right: auto;
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

/* Canonical r-field row, matching the project pattern from the
   failover settings dialog. The min-width keeps the dropdowns from
   collapsing to icon-size on narrow viewports. */
.r-field {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  min-width: 9rem;
}

.r-field > label {
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--webui-text-muted);
}

.webui-issues-page__list {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
}

.webui-issues-page__footer {
  text-align: right;
  color: var(--webui-text-muted);
  font-size: 0.8rem;
}
</style>
