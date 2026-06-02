<script setup lang="ts">
import { storeToRefs } from 'pinia';
import { computed } from 'vue';

import { useIssueStore } from '@/entities/issue';

const issueStore = useIssueStore();
const { summary } = storeToRefs(issueStore);

const variant = computed<'critical' | 'warning' | 'idle'>(() => {
  if (summary.value.critical > 0) return 'critical';
  if (summary.value.warning > 0) return 'warning';
  return 'idle';
});
</script>

<template>
  <router-link
    to="/issues"
    :class="['webui-issues-badge', `webui-issues-badge--${variant}`]"
    :aria-label="`${summary.total} issues`"
  >
    <i v-if="summary.critical > 0" class="pi pi-exclamation-circle" aria-hidden="true" />
    <i v-else-if="summary.warning > 0" class="pi pi-exclamation-triangle" aria-hidden="true" />
    <i v-else class="pi pi-check-circle" aria-hidden="true" />
    <span class="webui-issues-badge__counts">
      <template v-if="summary.total > 0">
        <span
          v-if="summary.critical > 0"
          class="webui-issues-badge__chip webui-issues-badge__chip--critical"
          >{{ summary.critical }}</span
        >
        <span
          v-if="summary.warning > 0"
          class="webui-issues-badge__chip webui-issues-badge__chip--warning"
          >{{ summary.warning }}</span
        >
      </template>
      <span v-else class="webui-issues-badge__ok">OK</span>
    </span>
  </router-link>
</template>

<style scoped>
.webui-issues-badge {
  display: inline-flex;
  align-items: center;
  gap: 0.45rem;
  padding: 0.25rem 0.65rem;
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  background: rgba(255, 255, 255, 0.02);
  line-height: 1.2;
  text-decoration: none;
  color: var(--webui-text);
  font: inherit;
  font-weight: 600;
}

.webui-issues-badge:hover {
  border-color: var(--webui-accent);
}

.webui-issues-badge--idle {
  color: var(--webui-text-muted);
}
.webui-issues-badge--warning {
  color: var(--webui-warning);
}
.webui-issues-badge--critical {
  color: var(--webui-danger);
}

.webui-issues-badge__counts {
  display: inline-flex;
  gap: 0.3rem;
  font-family: var(--webui-font-mono);
}

.webui-issues-badge__chip {
  font-size: 0.7rem;
  padding: 0.05rem 0.4rem;
  border-radius: 999px;
  font-weight: 700;
  letter-spacing: 0.05em;
}

.webui-issues-badge__chip--critical {
  background: rgba(248, 81, 73, 0.2);
  color: var(--webui-danger);
}

.webui-issues-badge__chip--warning {
  background: rgba(210, 153, 34, 0.2);
  color: var(--webui-warning);
}

.webui-issues-badge__ok {
  font-size: 0.7rem;
  letter-spacing: 0.07em;
  color: var(--webui-success);
}
</style>
