<script setup lang="ts">
/**
 * Docker-style instance id: the trailing 12 hex chars of the UUID, with
 * a copy button and a tooltip carrying the full UUID.
 *
 * Kept as its own component so it memoizes on the `uuid` prop. The
 * cluster poller hands each row a fresh object every tick; an inline
 * `v-tooltip` would be re-bound on every one of those re-renders — the
 * directive's `updated` hook unbinds the live tooltip — so it flickers
 * away after ~1s. A stable child only re-renders when the uuid actually
 * changes, matching how the memory/buckets tooltips already behave.
 */
import { ref } from 'vue';
import Button from 'primevue/button';

import { containerId } from '../model/selectors';

const props = defineProps<{ uuid: string | null | undefined }>();

const copied = ref(false);
let resetTimer: ReturnType<typeof setTimeout> | null = null;

function copy() {
  if (!props.uuid || !navigator?.clipboard) return;
  void navigator.clipboard.writeText(props.uuid);
  copied.value = true;
  if (resetTimer) clearTimeout(resetTimer);
  resetTimer = setTimeout(() => {
    copied.value = false;
  }, 1500);
}
</script>

<template>
  <span class="webui-instance-id">
    <span v-tooltip.top="'UUID: ' + (uuid ?? 'unknown')" class="webui-instance-id__code">
      {{ containerId(uuid) }}
    </span>
    <Button
      v-if="uuid"
      v-tooltip.top="copied ? 'Copied' : 'Copy UUID'"
      :icon="copied ? 'pi pi-check' : 'pi pi-copy'"
      severity="secondary"
      text
      rounded
      size="small"
      aria-label="Copy UUID"
      class="webui-instance-id__copy"
      @click="copy"
    />
  </span>
</template>

<style scoped>
.webui-instance-id {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
}
.webui-instance-id__code {
  font-family: var(--webui-font-mono);
  color: var(--webui-text-muted);
}
.webui-instance-id__copy {
  flex: 0 0 auto;
}
</style>
