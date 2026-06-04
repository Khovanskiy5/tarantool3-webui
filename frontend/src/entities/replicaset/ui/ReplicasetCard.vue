<script setup lang="ts">
import { computed } from 'vue';

import { InstanceRow, type Instance } from '@/entities/instance';
import { InstanceActionsMenu } from '@/features/cluster-ops';

import type { Replicaset } from '../model/types';
import { getLeaderAlias } from '../model/selectors';

const props = defineProps<{
  replicaset: Replicaset;
  servers: readonly Instance[];
  selfAlias?: string | null;
  /** Toggle the operator-actions column on/off (admin only). */
  showActions?: boolean;
}>();

const emit = defineEmits<{
  (e: 'actionApplied'): void;
}>();

const statusClass = computed(() => `webui-rs-card--${props.replicaset.status}`);
const leader = computed(() => getLeaderAlias(props.replicaset));

// Replicaset-wide bucket aggregate for the tooltip on each row's
// buckets column. Every vshard storage replica reports the same
// bucket set (master + followers are mirrors), so we take the max
// across members instead of summing — summing would triple-count
// when all three replicas are healthy and read 3000 each. Null
// when the replicaset is not a vshard storage.
const replicasetBucketsTotal = computed(() => {
  let max: number | null = null;
  for (const s of props.servers) {
    const c = s.statistics?.bucketsCount;
    if (c == null) continue;
    if (max == null || c > max) max = c;
  }
  return max;
});
</script>

<template>
  <section :class="['webui-rs-card', statusClass]">
    <header class="webui-rs-card__head">
      <div>
        <h2 class="webui-rs-card__name">{{ replicaset.name }}</h2>
        <span v-if="replicaset.groupName" class="webui-rs-card__group">
          group: {{ replicaset.groupName }}
        </span>
      </div>
      <div class="webui-rs-card__meta">
        <span :class="['webui-rs-card__status', `webui-rs-card__status--${replicaset.status}`]">
          {{ replicaset.status }}
        </span>
        <span v-if="leader" class="webui-rs-card__leader">leader: {{ leader }}</span>
      </div>
    </header>
    <table class="webui-rs-card__table">
      <thead>
        <tr>
          <th>Instance</th>
          <th>UUID</th>
          <th>Status</th>
          <th>RO</th>
          <th>URI</th>
          <th>Version</th>
          <th>Uptime</th>
          <th>Buckets</th>
          <th>Memory</th>
          <th>Last error</th>
          <th v-if="showActions" class="webui-rs-card__actions-head">Actions</th>
        </tr>
      </thead>
      <tbody>
        <template v-for="srv in servers" :key="srv.alias">
          <InstanceRow
            :instance="srv"
            :is-self="srv.alias === selfAlias"
            :leader-alias="leader"
            :total-buckets="replicasetBucketsTotal"
          >
            <td v-if="showActions" class="webui-rs-card__actions-cell">
              <InstanceActionsMenu
                :alias="srv.alias"
                :is-leader="leader === srv.alias"
                @changed="emit('actionApplied')"
              />
            </td>
          </InstanceRow>
        </template>
      </tbody>
    </table>
  </section>
</template>

<style scoped>
.webui-rs-card {
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
  padding: 1rem 1rem 0.5rem;
  border-top-width: 3px;
}

.webui-rs-card--healthy {
  border-top-color: var(--webui-success);
}
.webui-rs-card--degraded {
  border-top-color: var(--webui-warning);
}
.webui-rs-card--unhealthy {
  border-top-color: var(--webui-danger);
}
.webui-rs-card--unknown {
  border-top-color: var(--webui-text-muted);
}

.webui-rs-card__head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.75rem;
}

.webui-rs-card__name {
  margin: 0;
  font-size: 1.05rem;
  font-family: var(--webui-font-mono);
}

.webui-rs-card__group {
  font-size: 0.75rem;
  color: var(--webui-text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.webui-rs-card__meta {
  display: flex;
  gap: 0.75rem;
  align-items: center;
  flex-wrap: wrap;
  font-size: 0.85rem;
}

.webui-rs-card__status {
  text-transform: uppercase;
  letter-spacing: 0.06em;
  font-size: 0.7rem;
  font-weight: 700;
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
}

.webui-rs-card__status--healthy {
  background: rgba(63, 185, 80, 0.15);
  color: var(--webui-success);
}
.webui-rs-card__status--degraded {
  background: rgba(210, 153, 34, 0.18);
  color: var(--webui-warning);
}
.webui-rs-card__status--unhealthy {
  background: rgba(248, 81, 73, 0.18);
  color: var(--webui-danger);
}
.webui-rs-card__status--unknown {
  background: rgba(139, 148, 158, 0.18);
  color: var(--webui-text-muted);
}

.webui-rs-card__leader {
  color: var(--webui-text-muted);
  font-family: var(--webui-font-mono);
}

.webui-rs-card__table {
  width: 100%;
  border-collapse: collapse;
}

.webui-rs-card__table th {
  text-align: left;
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--webui-text-muted);
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--webui-border);
}

.webui-rs-card__actions-cell {
  padding: 0.35rem 0.6rem;
}

/* Keep the action buttons on a single line and left-aligned so the
   ACTIONS header sits directly above the first button. */
.webui-rs-card__table th.webui-rs-card__actions-head,
.webui-rs-card__actions-cell {
  text-align: left;
  white-space: nowrap;
}
</style>
