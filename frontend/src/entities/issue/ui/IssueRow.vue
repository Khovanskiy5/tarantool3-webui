<script setup lang="ts">
import { computed } from 'vue';

import type { Issue } from '../model/types';

const props = defineProps<{ issue: Issue }>();

const severityClass = computed(() => `webui-issue-row--${props.issue.severity.toLowerCase()}`);
const categoryLabel = computed(() => props.issue.category.toLowerCase());
const scopeLabel = computed(() => props.issue.scope.toLowerCase());
const severityLabel = computed(() => props.issue.severity.toLowerCase());
const target = computed(() => {
  if (props.issue.instance) return props.issue.instance;
  if (props.issue.replicaset) return props.issue.replicaset;
  return 'cluster';
});
</script>

<template>
  <article :class="['webui-issue-row', severityClass]">
    <div class="webui-issue-row__badge">
      <i
        :class="
          issue.severity === 'CRITICAL' ? 'pi pi-exclamation-circle' : 'pi pi-exclamation-triangle'
        "
      />
      <span class="webui-issue-row__severity">{{ severityLabel }}</span>
    </div>
    <div class="webui-issue-row__body">
      <header class="webui-issue-row__head">
        <span class="webui-issue-row__category">{{ categoryLabel }}</span>
        <span class="webui-issue-row__scope">{{ scopeLabel }}</span>
        <span class="webui-issue-row__target">{{ target }}</span>
      </header>
      <p class="webui-issue-row__message">{{ issue.message }}</p>
    </div>
  </article>
</template>

<style scoped>
.webui-issue-row {
  display: grid;
  grid-template-columns: 6rem 1fr;
  gap: 0.75rem;
  padding: 0.65rem 0.85rem;
  border: 1px solid var(--webui-border);
  border-left-width: 4px;
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
}

.webui-issue-row--critical {
  border-left-color: var(--webui-danger);
}

.webui-issue-row--warning {
  border-left-color: var(--webui-warning);
}

.webui-issue-row__badge {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-size: 0.7rem;
}

.webui-issue-row--critical .webui-issue-row__badge {
  color: var(--webui-danger);
}

.webui-issue-row--warning .webui-issue-row__badge {
  color: var(--webui-warning);
}

.webui-issue-row__head {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  font-size: 0.75rem;
  color: var(--webui-text-muted);
  margin-bottom: 0.25rem;
}

.webui-issue-row__category,
.webui-issue-row__scope {
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.webui-issue-row__target {
  color: var(--webui-text);
  font-family: var(--webui-font-mono);
}

.webui-issue-row__message {
  margin: 0;
  font-size: 0.9rem;
  line-height: 1.4;
  word-break: break-word;
}
</style>
