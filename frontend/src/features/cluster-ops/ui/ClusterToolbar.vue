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
      <button
        type="button"
        class="webui-cluster-toolbar__btn webui-cluster-toolbar__btn--solid"
        :disabled="ops.pending"
        @click="doResume"
      >
        Resume now
      </button>
    </div>
    <div v-else class="webui-cluster-toolbar__row">
      <button
        v-if="!showTtlForm"
        type="button"
        class="webui-cluster-toolbar__btn"
        :disabled="ops.pending"
        @click="showTtlForm = true"
      >
        Pause failover…
      </button>
      <div v-else class="webui-cluster-toolbar__ttl-form">
        <label class="webui-cluster-toolbar__ttl-label">
          TTL (seconds)
          <input
            v-model.number="ttlInput"
            type="number"
            min="60"
            max="86400"
            class="webui-cluster-toolbar__ttl-input"
          />
        </label>
        <button
          type="button"
          class="webui-cluster-toolbar__btn webui-cluster-toolbar__btn--solid"
          :disabled="ops.pending"
          @click="doPause"
        >
          Confirm pause
        </button>
        <button
          type="button"
          class="webui-cluster-toolbar__btn"
          :disabled="ops.pending"
          @click="showTtlForm = false"
        >
          Cancel
        </button>
      </div>
    </div>
    <p
      v-if="banner"
      :class="[
        'webui-cluster-toolbar__msg',
        banner.severity === 'err'
          ? 'webui-cluster-toolbar__msg--err'
          : 'webui-cluster-toolbar__msg--ok',
      ]"
    >
      {{ banner.text }}
    </p>
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
  display: flex;
  align-items: center;
  gap: 0.45rem;
  font-size: 0.85rem;
  color: var(--webui-text-muted);
}

.webui-cluster-toolbar__ttl-input {
  width: 88px;
  padding: 0.3rem 0.45rem;
  border: 1px solid var(--webui-border);
  border-radius: 4px;
  font-family: var(--webui-font-mono);
  font-size: 0.9rem;
  background: var(--webui-bg);
  color: var(--webui-text);
}

.webui-cluster-toolbar__btn {
  padding: 0.4rem 0.85rem;
  font-size: 0.88rem;
  border-radius: 5px;
  border: 1px solid var(--webui-border);
  background: var(--webui-bg);
  color: var(--webui-text);
  cursor: pointer;
}

.webui-cluster-toolbar__btn:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}

.webui-cluster-toolbar__btn:disabled {
  cursor: not-allowed;
  opacity: 0.45;
}

.webui-cluster-toolbar__btn--solid {
  background: var(--webui-accent);
  color: #0e1117;
  border-color: var(--webui-accent);
  font-weight: 600;
}

.webui-cluster-toolbar__btn--solid:not(:disabled):hover {
  background: #6cb8e3;
  border-color: #6cb8e3;
  color: #0e1117;
}

.webui-cluster-toolbar__msg {
  margin: 0;
  font-size: 0.85rem;
  padding: 0.4rem 0.65rem;
  border-radius: 4px;
  border: 1px solid transparent;
}

.webui-cluster-toolbar__msg--ok {
  background: rgba(63, 185, 80, 0.12);
  border-color: rgba(63, 185, 80, 0.4);
  color: var(--webui-success);
}

.webui-cluster-toolbar__msg--err {
  background: rgba(248, 81, 73, 0.12);
  border-color: rgba(248, 81, 73, 0.4);
  color: var(--webui-danger);
}
</style>
