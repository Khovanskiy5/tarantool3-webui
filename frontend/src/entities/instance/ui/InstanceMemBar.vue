<script setup lang="ts">
import { computed } from 'vue';

import { formatBytes } from '@/shared/lib/format';

/**
 * Compact memtx memory indicator for the cluster page — mirrors
 * Cartridge's `ReplicasetListMemStat`. Renders a small horizontal
 * progress bar tinted by usage *and* fragmentation, with a tooltip
 * carrying the absolute "used / quota" reading in human-readable
 * bytes.
 *
 * Fragmentation thresholds (high / medium / low) come straight from
 * Cartridge's `calculateMemoryFragmentationLevel` in
 * `cartridge-2.17.1/webui/src/misc/memoryStatistics.ts:14-25`. The
 * three slab ratios are nullable individually because the issues
 * scanner is the upstream and may not have populated this peer yet;
 * we degrade to "low" when any ratio is missing.
 */
const props = defineProps<{
  arenaUsedRatio?: number | null;
  quotaUsedRatio?: number | null;
  itemsUsedRatio?: number | null;
  quotaUsed?: number | null;
  quotaSize?: number | null;
}>();

type FragmentationLevel = 'high' | 'medium' | 'low';

const fragmentationLevel = computed<FragmentationLevel>(() => {
  const a = props.arenaUsedRatio;
  const q = props.quotaUsedRatio;
  const i = props.itemsUsedRatio;
  if (a == null || q == null || i == null) return 'low';
  if (i > 0.9 && a > 0.9 && q > 0.9) return 'high';
  if (i > 0.6 && a > 0.9 && q > 0.9) return 'medium';
  return 'low';
});

// Percentage shown on the bar. We prefer `quota_used_ratio` when
// supplied (it's already a number in [0, 1] from the backend's
// `parse_ratio`); when only absolute bytes are available we fall
// back to `quota_used / quota_size`. Both code paths floor at 1%
// so a populated bar is always visible, matching Cartridge.
const percentage = computed(() => {
  let raw: number | null = null;
  if (props.quotaUsedRatio != null) {
    raw = props.quotaUsedRatio * 100;
  } else if (props.quotaUsed != null && props.quotaSize && props.quotaSize > 0) {
    raw = (props.quotaUsed / props.quotaSize) * 100;
  }
  if (raw == null) return null;
  return Math.min(100, Math.max(1, raw));
});

const barColorClass = computed(() => {
  const p = percentage.value ?? 0;
  if (fragmentationLevel.value === 'high' || p >= 90) return 'webui-membar__fill--danger';
  if (fragmentationLevel.value === 'medium' || p >= 70) return 'webui-membar__fill--warn';
  return 'webui-membar__fill--ok';
});

const tooltip = computed(() => {
  if (props.quotaUsed == null || props.quotaSize == null) {
    return 'Memory usage not available yet';
  }
  const base = `Memory usage: ${formatBytes(props.quotaUsed)} / ${formatBytes(props.quotaSize)}`;
  if (fragmentationLevel.value === 'high') return `${base} — running out of memory`;
  if (fragmentationLevel.value === 'medium') return `${base} — highly fragmented`;
  return base;
});

const hidden = computed(() => percentage.value == null);
const widthStyle = computed(() => ({ width: `${percentage.value ?? 0}%` }));
</script>

<template>
  <span v-if="!hidden" v-tooltip.top="tooltip" class="webui-membar">
    <span class="webui-membar__track">
      <span :class="['webui-membar__fill', barColorClass]" :style="widthStyle" />
    </span>
    <span
      v-if="fragmentationLevel !== 'low'"
      :class="[
        'webui-membar__chip',
        fragmentationLevel === 'high' ? 'webui-membar__chip--danger' : 'webui-membar__chip--warn',
      ]"
      :aria-label="
        fragmentationLevel === 'high' ? 'Running out of memory' : 'Memory is highly fragmented'
      "
      >!</span
    >
  </span>
  <span v-else class="webui-membar webui-membar--empty" aria-hidden="true">—</span>
</template>

<style scoped>
.webui-membar {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.75rem;
  color: var(--webui-text-muted);
}

.webui-membar__track {
  display: inline-block;
  width: 72px;
  height: 6px;
  border-radius: 3px;
  background: rgba(139, 148, 158, 0.18);
  overflow: hidden;
  position: relative;
}

.webui-membar__fill {
  display: block;
  height: 100%;
  border-radius: 3px;
  transition: width 0.2s ease-out;
}

.webui-membar__fill--ok {
  background: var(--webui-success);
}

.webui-membar__fill--warn {
  background: var(--webui-warning);
}

.webui-membar__fill--danger {
  background: var(--webui-danger);
}

.webui-membar__chip {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  font-size: 0.65rem;
  font-weight: 700;
  color: #fff;
  flex-shrink: 0;
}

.webui-membar__chip--warn {
  background: var(--webui-warning);
}

.webui-membar__chip--danger {
  background: var(--webui-danger);
}

.webui-membar--empty {
  font-family: var(--webui-font-mono);
}
</style>
