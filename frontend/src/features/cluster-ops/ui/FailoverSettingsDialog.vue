<script setup lang="ts">
/**
 * Failover settings modal (Phase 5 Task 5.19).
 *
 * Wraps the backend's `setFailoverMode` mutation behind a per-
 * mode form. The four modes pick mechanically different sets of
 * knobs:
 *
 *   * `off`         — `replication.failover: off`. Operator chooses
 *                     whether the supervised OS agent runs on top
 *                     (agent=true → effectively `supervised`).
 *   * `manual`      — operator sets `replicasets.<rs>.leader` from
 *                     the config editor / cluster page. The mode
 *                     itself only needs synchro tuning.
 *   * `election`    — Tarantool raft. Exposes election_timeout +
 *                     election_fencing_mode in addition to the
 *                     synchro pair.
 *   * `supervised`  — shorthand for `off + agent: true` on the
 *                     backend. Same knobs as `off + agent`, with
 *                     an extra `agent_params` sub-form for
 *                     lease_ttl_sec etc.
 *
 * The shared knobs (synchro_quorum / synchro_timeout) live in
 * every panel. A live N/2+1 warning fires when the operator
 * picks a numeric quorum below the safe floor — the backend
 * rejects it, but flagging early keeps the operator from
 * needing a round-trip to learn that.
 */
import { computed, nextTick, ref, watch } from 'vue';
import Dropdown from 'primevue/dropdown';

import { useClusterOpsStore } from '../model/store';

const props = defineProps<{
  open: boolean;
  /** Current cluster-wide mode (`replication.failover`). */
  initialMode: string;
  /** Server count for the N/2+1 quorum hint. */
  instanceCount: number;
  /**
   * Whether the open-source supervised agent is currently enabled.
   * Used to seed the "Enable supervised agent on top of failover:
   * off" checkbox when the dialog opens — otherwise an operator
   * who already has the agent running would see an unchecked box
   * and assume it's disabled.
   */
  initialAgentEnabled?: boolean;
}>();

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'applied'): void;
}>();

const ops = useClusterOpsStore();

type Mode = 'off' | 'manual' | 'election' | 'supervised';
const VALID_MODES: Mode[] = ['off', 'manual', 'election', 'supervised'];

const MODE_OPTIONS = [
  { value: 'off', label: 'off' },
  { value: 'manual', label: 'manual' },
  { value: 'election', label: 'election (raft)' },
  { value: 'supervised', label: 'supervised (OS agent)' },
];

const FENCING_OPTIONS = [
  { value: '', label: '(keep current)' },
  { value: 'off', label: 'off' },
  { value: 'soft', label: 'soft' },
  { value: 'strict', label: 'strict' },
];

const mode = ref<Mode>('off');
// Synchro knobs are shared. Empty string means "do not touch" so
// the backend keeps the current value.
const synchroQuorum = ref<string>('');
const synchroTimeout = ref<string>('');
// Election-only knobs.
const electionTimeout = ref<string>('');
const electionFencing = ref<'' | 'off' | 'soft' | 'strict'>('');
// off + supervised: should the OS agent run?
const agentEnabled = ref<boolean>(false);
// supervised agent_params.
const leaseTtlSec = ref<string>('');

const banner = ref<{ severity: 'ok' | 'err' | 'info'; text: string } | null>(null);
const diffSummary = ref<string[] | null>(null);

const quorumFloor = computed(() =>
  props.instanceCount > 1 ? Math.floor(props.instanceCount / 2) + 1 : 1,
);
const quorumWarning = computed<string | null>(() => {
  const v = synchroQuorum.value.trim();
  if (v === '') return null;
  const n = Number(v);
  if (Number.isNaN(n)) return null;
  if (n < quorumFloor.value) {
    return (
      `synchro_quorum ${n} is below N/2+1 (${quorumFloor.value}) — ` +
      'two partitions could both reach quorum independently. The ' +
      'backend will refuse the commit.'
    );
  }
  return null;
});

watch(
  () => props.open,
  async (now) => {
    if (now) {
      // Reset against current cluster state. The initialMode prop
      // tells us where the operator starts so the dropdown reflects
      // the existing mode without an extra round-trip.
      const m = VALID_MODES.includes(props.initialMode as Mode)
        ? (props.initialMode as Mode)
        : 'off';
      mode.value = m;
      // Reflect the live agent state. The agent is independent of
      // the raft `mode` — it can run on top of `off`. The dialog
      // previously only set the checkbox when mode === supervised,
      // so an operator with `mode=off + agent=true` saw the
      // checkbox unchecked and could accidentally disable the
      // agent on Apply.
      agentEnabled.value = props.initialAgentEnabled === true || m === 'supervised';
      synchroQuorum.value = '';
      synchroTimeout.value = '';
      electionTimeout.value = '';
      electionFencing.value = '';
      leaseTtlSec.value = '';
      banner.value = null;
      diffSummary.value = null;
      await nextTick();
    }
  },
);

function buildParams(): Record<string, unknown> | null {
  // Empty fields are omitted — the backend keeps the current
  // value for any knob we do not pass.
  const params: Record<string, unknown> = {};
  if (synchroQuorum.value.trim() !== '') {
    const n = Number(synchroQuorum.value);
    if (Number.isNaN(n)) {
      banner.value = { severity: 'err', text: 'synchro_quorum must be a number' };
      return null;
    }
    params.synchro_quorum = n;
  }
  if (synchroTimeout.value.trim() !== '') {
    const n = Number(synchroTimeout.value);
    if (Number.isNaN(n) || n <= 0) {
      banner.value = { severity: 'err', text: 'synchro_timeout must be a positive number' };
      return null;
    }
    params.synchro_timeout = n;
  }
  if (mode.value === 'election') {
    if (electionTimeout.value.trim() !== '') {
      const n = Number(electionTimeout.value);
      if (Number.isNaN(n) || n <= 0) {
        banner.value = { severity: 'err', text: 'election_timeout must be a positive number' };
        return null;
      }
      params.election_timeout = n;
    }
    if (electionFencing.value !== '') {
      params.election_fencing_mode = electionFencing.value;
    }
  }
  if (mode.value === 'off' && agentEnabled.value) {
    params.agent = true;
  }
  if (mode.value === 'supervised' && leaseTtlSec.value.trim() !== '') {
    const n = Number(leaseTtlSec.value);
    if (Number.isNaN(n) || n <= 0) {
      banner.value = { severity: 'err', text: 'lease_ttl_sec must be a positive number' };
      return null;
    }
    params.agent_params = { lease_ttl_sec: n };
  }
  return params;
}

async function runPreview() {
  const params = buildParams();
  if (params === null) return;
  banner.value = null;
  const res = await ops.setFailoverMode(
    mode.value,
    Object.keys(params).length === 0 ? null : params,
    false,
  );
  if (!res.ok) {
    banner.value = { severity: 'err', text: res.message };
    diffSummary.value = null;
    return;
  }
  diffSummary.value = res.diffSummary ?? [];
  banner.value = {
    severity: 'info',
    text: `Preview ok — ${res.message}. Press Apply to commit.`,
  };
}

async function runApply() {
  const params = buildParams();
  if (params === null) return;
  banner.value = null;
  const res = await ops.setFailoverMode(
    mode.value,
    Object.keys(params).length === 0 ? null : params,
    true,
  );
  if (!res.ok) {
    banner.value = { severity: 'err', text: res.message };
    return;
  }
  banner.value = { severity: 'ok', text: res.message };
  emit('applied');
  setTimeout(() => emit('close'), 1200);
}

function onCancel() {
  if (ops.pending) return;
  emit('close');
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="webui-fo-settings">
      <div class="webui-fo-settings__backdrop" @click="onCancel" />
      <div class="webui-fo-settings__panel" role="dialog" aria-modal="true">
        <header class="webui-fo-settings__head">
          <h2 class="webui-fo-settings__title">Failover settings</h2>
          <p class="webui-fo-settings__hint">
            Routes through <code>setFailoverMode</code>. Empty fields keep the current cluster value
            untouched.
          </p>
        </header>
        <div class="webui-fo-settings__body">
          <label class="webui-fo-settings__field">
            Mode
            <Dropdown
              v-model="mode"
              :options="MODE_OPTIONS"
              option-label="label"
              option-value="value"
              class="webui-fo-settings__dropdown"
            />
          </label>

          <fieldset class="webui-fo-settings__group">
            <legend>Synchro</legend>
            <div class="webui-fo-settings__row">
              <label class="webui-fo-settings__field">
                synchro_quorum
                <input
                  v-model="synchroQuorum"
                  type="text"
                  inputmode="numeric"
                  class="webui-fo-settings__input"
                  :placeholder="`N/2+1=${quorumFloor}`"
                />
              </label>
              <label class="webui-fo-settings__field">
                synchro_timeout (sec)
                <input
                  v-model="synchroTimeout"
                  type="number"
                  min="0"
                  step="0.1"
                  class="webui-fo-settings__input"
                  placeholder="3"
                />
              </label>
            </div>
            <p v-if="quorumWarning" class="webui-fo-settings__msg webui-fo-settings__msg--err">
              {{ quorumWarning }}
            </p>
          </fieldset>

          <fieldset v-if="mode === 'election'" class="webui-fo-settings__group">
            <legend>Election (raft)</legend>
            <div class="webui-fo-settings__row">
              <label class="webui-fo-settings__field">
                election_timeout (sec)
                <input
                  v-model="electionTimeout"
                  type="number"
                  min="0"
                  step="0.1"
                  class="webui-fo-settings__input"
                  placeholder="5"
                />
              </label>
              <label class="webui-fo-settings__field">
                election_fencing_mode
                <Dropdown
                  v-model="electionFencing"
                  :options="FENCING_OPTIONS"
                  option-label="label"
                  option-value="value"
                  class="webui-fo-settings__dropdown"
                />
              </label>
            </div>
          </fieldset>

          <fieldset v-if="mode === 'off'" class="webui-fo-settings__group">
            <legend>Open-source agent</legend>
            <label class="webui-fo-settings__field webui-fo-settings__field--row">
              <input v-model="agentEnabled" type="checkbox" class="webui-fo-settings__checkbox" />
              Enable supervised agent on top of <code>failover: off</code>
            </label>
          </fieldset>

          <fieldset v-if="mode === 'supervised'" class="webui-fo-settings__group">
            <legend>Agent parameters</legend>
            <label class="webui-fo-settings__field">
              lease_ttl_sec
              <input
                v-model="leaseTtlSec"
                type="number"
                min="1"
                step="1"
                class="webui-fo-settings__input"
                placeholder="3"
              />
            </label>
          </fieldset>

          <div v-if="diffSummary && diffSummary.length > 0" class="webui-fo-settings__diff">
            <strong
              >Diff ({{ diffSummary.length }} op{{ diffSummary.length === 1 ? '' : 's' }}):</strong
            >
            <ul>
              <li v-for="(op, idx) in diffSummary" :key="idx">
                <code>{{ op }}</code>
              </li>
            </ul>
          </div>
          <p
            v-if="banner"
            :class="[
              'webui-fo-settings__msg',
              banner.severity === 'err'
                ? 'webui-fo-settings__msg--err'
                : banner.severity === 'info'
                  ? 'webui-fo-settings__msg--info'
                  : 'webui-fo-settings__msg--ok',
            ]"
          >
            {{ banner.text }}
          </p>
        </div>
        <footer class="webui-fo-settings__foot">
          <button
            type="button"
            class="webui-fo-settings__btn"
            :disabled="ops.pending"
            @click="onCancel"
          >
            Cancel
          </button>
          <button
            type="button"
            class="webui-fo-settings__btn"
            :disabled="ops.pending"
            @click="runPreview"
          >
            Preview
          </button>
          <button
            type="button"
            class="webui-fo-settings__btn webui-fo-settings__btn--solid"
            :disabled="ops.pending"
            @click="runApply"
          >
            Apply
          </button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.webui-fo-settings {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.webui-fo-settings__backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
}

.webui-fo-settings__panel {
  position: relative;
  width: min(560px, 94vw);
  max-height: 90vh;
  overflow-y: auto;
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
  display: flex;
  flex-direction: column;
  color: var(--webui-text);
}

.webui-fo-settings__head {
  padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--webui-border);
}

.webui-fo-settings__title {
  margin: 0 0 0.25rem 0;
  font-size: 1.05rem;
  font-weight: 600;
}

.webui-fo-settings__hint {
  margin: 0;
  font-size: 0.82rem;
  color: var(--webui-text-muted);
}

.webui-fo-settings__hint code {
  font-family: var(--webui-font-mono);
}

.webui-fo-settings__body {
  padding: 1rem 1.25rem;
  display: flex;
  flex-direction: column;
  gap: 0.85rem;
}

.webui-fo-settings__group {
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  padding: 0.6rem 0.85rem 0.85rem;
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  margin: 0;
}

.webui-fo-settings__group legend {
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--webui-text-muted);
  padding: 0 0.4rem;
}

.webui-fo-settings__row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.85rem;
}

.webui-fo-settings__field {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  font-size: 0.85rem;
  color: var(--webui-text-muted);
}

.webui-fo-settings__field--row {
  flex-direction: row;
  align-items: center;
  gap: 0.5rem;
  color: var(--webui-text);
}

.webui-fo-settings__input {
  font-family: var(--webui-font-mono);
  font-size: 0.9rem;
  padding: 0.4rem 0.55rem;
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  background: var(--webui-bg);
  color: var(--webui-text);
}

.webui-fo-settings__input:focus {
  outline: 2px solid var(--webui-accent);
  outline-offset: -1px;
}

.webui-fo-settings__dropdown {
  width: 100%;
}

.webui-fo-settings__checkbox {
  accent-color: var(--webui-accent);
}

.webui-fo-settings__diff {
  font-size: 0.85rem;
  background: var(--webui-bg);
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  padding: 0.6rem 0.85rem;
}

.webui-fo-settings__diff ul {
  margin: 0.4rem 0 0;
  padding-left: 1.2rem;
}

.webui-fo-settings__diff code {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
  color: var(--webui-text-muted);
}

.webui-fo-settings__msg {
  margin: 0;
  font-size: 0.85rem;
  padding: 0.4rem 0.65rem;
  border-radius: 4px;
  border: 1px solid transparent;
}

.webui-fo-settings__msg--ok {
  background: rgba(63, 185, 80, 0.12);
  border-color: rgba(63, 185, 80, 0.4);
  color: var(--webui-success);
}

.webui-fo-settings__msg--info {
  background: rgba(78, 168, 222, 0.12);
  border-color: rgba(78, 168, 222, 0.4);
  color: var(--webui-accent);
}

.webui-fo-settings__msg--err {
  background: rgba(248, 81, 73, 0.12);
  border-color: rgba(248, 81, 73, 0.4);
  color: var(--webui-danger);
}

.webui-fo-settings__foot {
  padding: 0.85rem 1.25rem;
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  border-top: 1px solid var(--webui-border);
}

.webui-fo-settings__btn {
  padding: 0.5rem 1rem;
  font-size: 0.92rem;
  border-radius: 5px;
  cursor: pointer;
  border: 1px solid var(--webui-border);
  background: var(--webui-bg);
  color: var(--webui-text);
  font-weight: 500;
}

.webui-fo-settings__btn:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}

.webui-fo-settings__btn:disabled {
  cursor: not-allowed;
  opacity: 0.4;
}

.webui-fo-settings__btn--solid {
  background: var(--webui-accent);
  color: #0e1117;
  border-color: var(--webui-accent);
}

.webui-fo-settings__btn--solid:not(:disabled):hover {
  background: #6cb8e3;
  border-color: #6cb8e3;
  color: #0e1117;
}
</style>
