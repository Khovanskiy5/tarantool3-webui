<script setup lang="ts">
import { computed } from 'vue';

import { formatInteger } from '@/shared/lib/format';

/**
 * Buckets indicator — a small bucket icon next to the number of
 * vshard buckets owned by this storage. Mirrors Cartridge's
 * `ReplicasetListBuckets`: hidden entirely for non-storage peers
 * (routers, sharding-disabled instances), so the row column simply
 * collapses to nothing instead of rendering a sad placeholder.
 *
 * `total` (cluster-wide bucket count for the vshard group) is shown
 * in the tooltip only — keeps the inline label compact.
 */
const props = defineProps<{
  count: number | null | undefined;
  total?: number | null;
}>();

const formattedCount = computed(() => formatInteger(props.count));

const tooltip = computed(() => {
  if (props.total == null) return `Buckets owned: ${formattedCount.value}`;
  return `Buckets owned: ${formattedCount.value} / ${formatInteger(props.total)}`;
});

const hidden = computed(() => props.count == null);
</script>

<template>
  <span v-if="!hidden" v-tooltip.top="tooltip" class="webui-buckets">
    <svg class="webui-buckets__icon" viewBox="0 0 16 16" aria-hidden="true">
      <!--
        Bucket silhouette: trapezoid body + thin handle. The SVG is
        inlined so the component stays self-contained and renders
        with currentColor (set by CSS so we can theme it).
      -->
      <path
        d="M2.5 3.5h11l-1 9.2a1 1 0 0 1-1 .8h-7a1 1 0 0 1-1-.8l-1-9.2Zm1.4 1.2.4 4h8.4l.4-4H3.9Z"
        fill="currentColor"
      />
      <path d="M5 2.5c0-.6.4-1 1-1h4c.6 0 1 .4 1 1V4h-1V2.5H6V4H5V2.5Z" fill="currentColor" />
    </svg>
    <span class="webui-buckets__count">{{ formattedCount }}</span>
  </span>
  <span v-else class="webui-buckets webui-buckets--empty" aria-hidden="true">—</span>
</template>

<style scoped>
.webui-buckets {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  font-size: 0.8rem;
  font-family: var(--webui-font-mono);
  color: var(--webui-text);
  white-space: nowrap;
}

.webui-buckets__icon {
  width: 14px;
  height: 14px;
  color: var(--webui-text-muted);
  flex-shrink: 0;
}

.webui-buckets__count {
  line-height: 1;
}

.webui-buckets--empty {
  color: var(--webui-text-muted);
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
}
</style>
