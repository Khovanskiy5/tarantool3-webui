<script setup lang="ts">
/**
 * Global cluster-page action toolbar (Phase 5).
 *
 * Renders:
 *   * Pause / Resume button driven by `failoverAgentStatus.paused_until`.
 *     When paused, a yellow banner shows the expiry time + Resume.
 *     When unpaused, a default "Pause failover" button opens a small
 *     prompt to pick TTL.
 *
 * The store refresh comes from upstream — this component takes
 * `pausedUntil` as a prop so the parent page controls the polling
 * cadence (already wired via WS in the cluster store).
 */
import { computed, ref } from 'vue';
import Button from 'primevue/button';
import InputNumber from 'primevue/inputnumber';
import Message from 'primevue/message';

import { useClusterOpsStore } from '../model/store';

const props = defineProps<{
  /** Epoch seconds when the pause expires, or null when unpaused. */
  pausedUntil: number | null;
}>();

const emit = defineEmits<{
  (e: 'refresh'): void;
}>();

const ops = useClusterOpsStore();
const ttlInput = ref<number>(60 * 60); // default 1h
const showTtlForm = ref(false);
const banner = ref<{ severity: 'ok' | 'err'; text: string } | null>(null);

const expiresInSec = computed<number | null>(() => {
  if (props.pausedUntil == null) return null;
  return Math.max(0, Math.round(props.pausedUntil - Date.now() / 1000));
});

const isPaused = computed(() => expiresInSec.value != null && expiresInSec.value > 0);

function formatExpiry(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m ${s}s`;
}

async function doPause() {
  const r = await ops.pauseFailover(ttlInput.value);
  banner.value = r.ok ? { severity: 'ok', text: r.message } : { severity: 'err', text: r.message };
  showTtlForm.value = false;
  emit('refresh');
}

async function doResume() {
  const r = await ops.resumeFailover();
  banner.value = r.ok ? { severity: 'ok', text: r.message } : { severity: 'err', text: r.message };
  emit('refresh');
}
</script>

<template>
  <div class="webui-cluster-toolbar">
    <div v-if="isPaused" class="webui-cluster-toolbar__pause-banner" role="status">
      <span class="webui-cluster-toolbar__pause-icon" aria-hidden="true">⏸</span>
      <span class="webui-cluster-toolbar__pause-label">
        Failover PAUSED — auto-resume in
        <strong>{{ expiresInSec != null ? formatExpiry(expiresInSec) : '?' }}</strong>
      </span>
      <Button
        label="Resume now"
        size="small"
        severity="warn"
        :disabled="ops.pending"
        @click="doResume"
      />
    </div>
    <div v-else class="webui-cluster-toolbar__row">
      <Button
        v-if="!showTtlForm"
        label="Pause failover…"
        icon="pi pi-pause"
        size="small"
        outlined
        :disabled="ops.pending"
        @click="showTtlForm = true"
      />
      <div v-else class="webui-cluster-toolbar__ttl-form">
        <label class="webui-cluster-toolbar__ttl-label" for="webui-toolbar-ttl"
          >TTL (seconds)</label
        >
        <InputNumber
          v-model="ttlInput"
          input-id="webui-toolbar-ttl"
          :min="60"
          :max="86400"
          :use-grouping="false"
          class="webui-cluster-toolbar__ttl-input"
        />
        <Button label="Confirm pause" size="small" :disabled="ops.pending" @click="doPause" />
        <Button
          label="Cancel"
          size="small"
          text
          :disabled="ops.pending"
          @click="showTtlForm = false"
        />
      </div>
    </div>
    <Message
      v-if="banner"
      :severity="banner.severity === 'err' ? 'error' : 'success'"
      variant="simple"
      size="small"
    >
      {{ banner.text }}
    </Message>
  </div>
</template>

<style scoped>
.webui-cluster-toolbar {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.75rem 1rem;
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
  color: var(--webui-text);
}

.webui-cluster-toolbar__row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.webui-cluster-toolbar__pause-banner {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  background: rgba(210, 153, 34, 0.12);
  border: 1px solid var(--webui-warning);
  border-radius: var(--webui-radius);
  padding: 0.6rem 0.85rem;
  color: var(--webui-warning);
}

.webui-cluster-toolbar__pause-icon {
  font-size: 1.25rem;
}

.webui-cluster-toolbar__pause-label {
  flex: 1;
  font-size: 0.92rem;
}

.webui-cluster-toolbar__ttl-form {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.webui-cluster-toolbar__ttl-label {
  font-size: 0.85rem;
  color: var(--webui-text-muted);
}

.webui-cluster-toolbar__ttl-input {
  width: 110px;
  flex: 0 0 auto;
}
/* The class lands on the `.p-inputnumber` wrapper; the inner <input>
   keeps its own default width and would otherwise overflow the fixed
   wrapper and overlap the Confirm button. Pin it to the wrapper. */
.webui-cluster-toolbar__ttl-input :deep(.p-inputnumber-input) {
  width: 100%;
}
</style>
