<script setup lang="ts">
import { computed } from 'vue';

import type { Instance } from '../model/types';
import { isLeader, reachability, shortUuid } from '../model/selectors';

const props = defineProps<{ instance: Instance; isSelf?: boolean }>();

const stateClass = computed(() => {
  const r = reachability(props.instance);
  return `webui-instance-row--${r}`;
});

const uptime = computed(() => {
  const u = props.instance.boxInfo?.uptime;
  if (u == null) return '—';
  if (u < 60) return `${Math.round(u)}s`;
  if (u < 3600) return `${Math.round(u / 60)}m`;
  return `${Math.round(u / 3600)}h`;
});

const roLabel = computed(() => {
  const ro = props.instance.boxInfo?.ro;
  if (ro == null) return null;
  return ro ? 'RO' : 'RW';
});

const reasonLabel = computed(() => props.instance.boxInfo?.roReason ?? '');
</script>

<template>
  <tr :class="['webui-instance-row', stateClass, { 'webui-instance-row--self': isSelf }]">
    <td class="webui-instance-row__alias">
      <span class="webui-instance-row__alias-text">{{ instance.alias }}</span>
      <span
        v-if="isSelf"
        class="webui-instance-row__chip webui-instance-row__chip--self"
        title="This is the instance answering the request"
      >self</span>
      <span
        v-if="isLeader(instance)"
        class="webui-instance-row__chip webui-instance-row__chip--leader"
      >leader</span>
    </td>
    <td class="webui-instance-row__uuid">{{ shortUuid(instance.uuid) }}</td>
    <td class="webui-instance-row__status">
      <span
        :class="[
          'webui-instance-row__dot',
          instance.reachable ? 'webui-instance-row__dot--ok' : 'webui-instance-row__dot--err',
        ]"
      />
      {{ instance.status }}
    </td>
    <td class="webui-instance-row__ro">
      <span v-if="roLabel" :title="reasonLabel">{{ roLabel }}</span>
      <span v-else>—</span>
    </td>
    <td class="webui-instance-row__uri">{{ instance.uri ?? '—' }}</td>
    <td class="webui-instance-row__version">
      {{ instance.boxInfo?.version ?? '—' }}
    </td>
    <td class="webui-instance-row__uptime">{{ uptime }}</td>
    <td class="webui-instance-row__error">
      <span v-if="instance.lastError" :title="instance.lastError">
        {{ instance.lastError }}
      </span>
    </td>
  </tr>
</template>

<style scoped>
.webui-instance-row {
  font-size: 0.85rem;
  border-bottom: 1px solid var(--webui-border);
}

.webui-instance-row td {
  padding: 0.45rem 0.6rem;
  vertical-align: middle;
}

.webui-instance-row--unreachable td {
  color: var(--webui-text-muted);
}

.webui-instance-row--self {
  background: rgba(78, 168, 222, 0.05);
}

.webui-instance-row__alias {
  font-family: var(--webui-font-mono);
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 0.4rem;
  white-space: nowrap;
}

.webui-instance-row__uuid {
  font-family: var(--webui-font-mono);
  color: var(--webui-text-muted);
}

.webui-instance-row__chip {
  display: inline-block;
  font-size: 0.65rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.05rem 0.4rem;
  border-radius: 999px;
  font-weight: 700;
}

.webui-instance-row__chip--self {
  background: rgba(78, 168, 222, 0.18);
  color: var(--webui-accent);
}

.webui-instance-row__chip--leader {
  background: rgba(63, 185, 80, 0.18);
  color: var(--webui-success);
}

.webui-instance-row__status {
  white-space: nowrap;
}

.webui-instance-row__dot {
  display: inline-block;
  width: 0.55rem;
  height: 0.55rem;
  border-radius: 50%;
  margin-right: 0.35rem;
  vertical-align: middle;
}

.webui-instance-row__dot--ok {
  background: var(--webui-success);
}

.webui-instance-row__dot--err {
  background: var(--webui-danger);
}

.webui-instance-row__error {
  color: var(--webui-danger);
  max-width: 20ch;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
