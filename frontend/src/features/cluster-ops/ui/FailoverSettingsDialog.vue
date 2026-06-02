<script setup lang="ts">
/**
 * Failover settings modal.
 *
 * Wraps the backend's `setFailoverMode` mutation behind a per-mode
 * form. Each of the four modes drives leadership through a
 * different mechanism — the dialog reveals only the knobs that
 * apply to the selected mode, and gates the Apply button on
 * client-side validation that mirrors the backend rules. The aim:
 * the operator cannot send a request that the server will refuse.
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
  { value: 'off', label: 'off — no automatic failover' },
  { value: 'manual', label: 'manual — static leader in YAML' },
  { value: 'election', label: 'election — built-in Raft' },
  { value: 'supervised', label: 'supervised — community agent (CE)' },
];

const MODE_BLURB: Record<Mode, string> = {
  off:
    'Tarantool failover is disabled. With the community agent enabled below, the agent ' +
    'drives leadership through etcd; without it, every instance follows its own ' +
    'database.mode and no automatic promotion happens on failure.',
  manual:
    'Leader per replicaset is named statically via replicaset.leader in the cluster ' +
    'YAML. No automatic failover — switching the leader is a config edit and commit.',
  election:
    'Tarantool elects a leader per replicaset using its built-in Raft. ' +
    'election_timeout controls how long a follower waits before starting a vote; ' +
    'election_fencing_mode controls what happens if the leader loses quorum.',
  supervised:
    'The bundled community agent runs an open-source equivalent of EE supervised: ' +
    'every peer races for an etcd lease, the winner becomes coordinator and writes ' +
    'per-replicaset appointments to etcd. Each peer\'s watcher reconciles ' +
    'box.cfg.read_only by reading those appointments. Lease TTL is the only ' +
    'frequently tuned knob — lower = faster failover, more etcd load.',
};

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

/**
 * Per-field validation. Empty value = "do not touch" (the backend
 * keeps the current cluster setting), so empty is always valid.
 * The rules mirror `validate_failover_params` in
 * backend/webui/graphql/resolvers/cluster_ops.lua — a value that
 * fails here would fail there too, so blocking client-side
 * removes the round-trip.
 */
function validateInteger(v: string, opts: { min?: number; field: string }): string | null {
  const t = v.trim();
  if (t === '') return null;
  if (!/^-?\d+$/.test(t)) return `${opts.field} must be a whole number`;
  const n = Number(t);
  if (opts.min !== undefined && n < opts.min) {
    return `${opts.field} must be ≥ ${opts.min}`;
  }
  return null;
}
function validatePositiveNumber(v: string, field: string): string | null {
  const t = v.trim();
  if (t === '') return null;
  const n = Number(t);
  if (Number.isNaN(n) || !Number.isFinite(n) || n <= 0) {
    return `${field} must be a positive number`;
  }
  return null;
}

// synchro_quorum has its own combined rule: accept either an integer
// >= N/2+1 OR the literal Tarantool formula `N/2 + 1` (with optional
// spaces). The backend accepts both shapes too.
const synchroQuorumError = computed<string | null>(() => {
  const v = synchroQuorum.value.trim();
  if (v === '') return null;
  if (/^N\s*\/\s*2\s*\+\s*1$/i.test(v)) return null;
  if (!/^\d+$/.test(v)) {
    return 'synchro_quorum must be a whole number or the formula `N/2 + 1`';
  }
  const n = Number(v);
  if (n < quorumFloor.value) {
    return (
      `synchro_quorum ${n} is below N/2+1 (${quorumFloor.value}) — ` +
      'two partitions could both reach quorum independently and split-brain. ' +
      'Increase the value or use the formula `N/2 + 1`.'
    );
  }
  return null;
});
const synchroTimeoutError = computed<string | null>(() =>
  validatePositiveNumber(synchroTimeout.value, 'synchro_timeout'),
);
const electionTimeoutError = computed<string | null>(() => {
  if (mode.value !== 'election') return null;
  return validatePositiveNumber(electionTimeout.value, 'election_timeout');
});
const leaseTtlError = computed<string | null>(() => {
  if (mode.value !== 'supervised') return null;
  return validateInteger(leaseTtlSec.value, { min: 1, field: 'lease_ttl_sec' });
});

// Mode-level guards that catch combinations the backend will reject
// or that produce a non-viable cluster (e.g. too few peers for raft).
const modeError = computed<string | null>(() => {
  if (mode.value === 'election' && props.instanceCount > 0 && props.instanceCount < 3) {
    return (
      `Raft election needs at least 3 voting instances for safety; current cluster has ` +
      `${props.instanceCount}. Add more peers before switching to election.`
    );
  }
  return null;
});

const validationErrors = computed<string[]>(() => {
  return [
    modeError.value,
    synchroQuorumError.value,
    synchroTimeoutError.value,
    electionTimeoutError.value,
    leaseTtlError.value,
  ].filter((s): s is string => s !== null);
});

const canSubmit = computed(
  () => !ops.pending && validationErrors.value.length === 0,
);

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
  // The reactive validators above already gate the Apply button, so
  // buildParams trusts the inputs and only shapes them. The defensive
  // bail-out below covers the corner case where Apply is triggered
  // before the next tick (e.g. via Enter on a stale form).
  if (validationErrors.value.length > 0) {
    banner.value = { severity: 'err', text: validationErrors.value[0] };
    return null;
  }
  const params: Record<string, unknown> = {};
  if (synchroQuorum.value.trim() !== '') {
    const v = synchroQuorum.value.trim();
    // Pass through the formula verbatim; numeric values go as numbers.
    params.synchro_quorum = /^\d+$/.test(v) ? Number(v) : v;
  }
  if (synchroTimeout.value.trim() !== '') {
    params.synchro_timeout = Number(synchroTimeout.value);
  }
  if (mode.value === 'election') {
    if (electionTimeout.value.trim() !== '') {
      params.election_timeout = Number(electionTimeout.value);
    }
    if (electionFencing.value !== '') {
      params.election_fencing_mode = electionFencing.value;
    }
  }
  // The "Enable agent" checkbox lives under `mode: off`. Always pass
  // the explicit boolean (rather than only on true) so flipping it
  // off actually disables the agent — otherwise the backend's
  // default-on rule for mode=off would silently re-enable it.
  if (mode.value === 'off') {
    params.agent = agentEnabled.value === true;
  }
  if (mode.value === 'supervised' && leaseTtlSec.value.trim() !== '') {
    params.agent_params = { lease_ttl_sec: Number(leaseTtlSec.value) };
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
            Choose how the cluster decides who is the read-write leader. Empty fields keep the
            current cluster value untouched.
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
          <p class="webui-fo-settings__blurb">{{ MODE_BLURB[mode] }}</p>
          <p v-if="modeError" class="webui-fo-settings__msg webui-fo-settings__msg--err">
            {{ modeError }}
          </p>

          <fieldset class="webui-fo-settings__group">
            <legend>Synchronous replication</legend>
            <div class="webui-fo-settings__row">
              <label class="webui-fo-settings__field">
                Write quorum <code>synchro_quorum</code>
                <input
                  v-model="synchroQuorum"
                  type="text"
                  inputmode="text"
                  class="webui-fo-settings__input"
                  :class="{ 'webui-fo-settings__input--err': synchroQuorumError }"
                  :placeholder="`N/2 + 1  (=${quorumFloor})`"
                />
                <small class="webui-fo-settings__field-help">
                  How many peers must ack a synchronous write before it commits. The safe minimum
                  is <code>N/2 + 1</code> ({{ quorumFloor }} for this cluster); a lower value
                  allows two partitions to commit independently (split-brain).
                </small>
              </label>
              <label class="webui-fo-settings__field">
                Sync timeout <code>synchro_timeout</code> (sec)
                <input
                  v-model="synchroTimeout"
                  type="number"
                  min="0"
                  step="0.1"
                  class="webui-fo-settings__input"
                  :class="{ 'webui-fo-settings__input--err': synchroTimeoutError }"
                  placeholder="3"
                />
                <small class="webui-fo-settings__field-help">
                  How long a sync write waits for quorum acks before it fails. Too low → flaky
                  writes under network jitter; too high → slow failure detection.
                </small>
              </label>
            </div>
            <p v-if="synchroQuorumError" class="webui-fo-settings__msg webui-fo-settings__msg--err">
              {{ synchroQuorumError }}
            </p>
            <p v-if="synchroTimeoutError" class="webui-fo-settings__msg webui-fo-settings__msg--err">
              {{ synchroTimeoutError }}
            </p>
          </fieldset>

          <fieldset v-if="mode === 'election'" class="webui-fo-settings__group">
            <legend>Raft election</legend>
            <div class="webui-fo-settings__row">
              <label class="webui-fo-settings__field">
                Election timeout <code>election_timeout</code> (sec)
                <input
                  v-model="electionTimeout"
                  type="number"
                  min="0"
                  step="0.1"
                  class="webui-fo-settings__input"
                  :class="{ 'webui-fo-settings__input--err': electionTimeoutError }"
                  placeholder="5"
                />
                <small class="webui-fo-settings__field-help">
                  How long a follower waits without leader heartbeats before starting a vote.
                  Lower = faster failover; too low = false elections during transient jitter.
                </small>
              </label>
              <label class="webui-fo-settings__field">
                Fencing <code>election_fencing_mode</code>
                <Dropdown
                  v-model="electionFencing"
                  :options="FENCING_OPTIONS"
                  option-label="label"
                  option-value="value"
                  class="webui-fo-settings__dropdown"
                />
                <small class="webui-fo-settings__field-help">
                  What an isolated leader does when it loses quorum. <code>soft</code> demotes
                  on quorum loss; <code>strict</code> also blocks reads from the isolated peer.
                </small>
              </label>
            </div>
            <p v-if="electionTimeoutError" class="webui-fo-settings__msg webui-fo-settings__msg--err">
              {{ electionTimeoutError }}
            </p>
          </fieldset>

          <fieldset v-if="mode === 'off'" class="webui-fo-settings__group">
            <legend>Community supervised agent</legend>
            <label class="webui-fo-settings__field webui-fo-settings__field--row">
              <input v-model="agentEnabled" type="checkbox" class="webui-fo-settings__checkbox" />
              Run the community supervised agent on top of <code>failover: off</code>
            </label>
            <small class="webui-fo-settings__field-help">
              When enabled, the bundled open-source agent acquires a coordinator lease in etcd
              and writes per-replicaset leader appointments. When disabled, leadership is
              controlled only by each instance's <code>database.mode</code> and no automatic
              promotion happens on failure.
            </small>
          </fieldset>

          <fieldset v-if="mode === 'supervised'" class="webui-fo-settings__group">
            <legend>Agent parameters</legend>
            <label class="webui-fo-settings__field">
              Lease TTL <code>lease_ttl_sec</code> (sec)
              <input
                v-model="leaseTtlSec"
                type="number"
                min="1"
                step="1"
                class="webui-fo-settings__input"
                :class="{ 'webui-fo-settings__input--err': leaseTtlError }"
                placeholder="3"
              />
              <small class="webui-fo-settings__field-help">
                How long the coordinator's etcd lease lives between keep-alives. Lower = faster
                detection that the coordinator died (and faster re-election), but more etcd
                load. Whole seconds, ≥ 1.
              </small>
            </label>
            <p v-if="leaseTtlError" class="webui-fo-settings__msg webui-fo-settings__msg--err">
              {{ leaseTtlError }}
            </p>
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
          <p v-if="validationErrors.length > 0" class="webui-fo-settings__foot-hint">
            Fix the highlighted fields above to enable Apply.
          </p>
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
            :disabled="!canSubmit"
            :title="validationErrors[0] ?? ''"
            @click="runPreview"
          >
            Preview
          </button>
          <button
            type="button"
            class="webui-fo-settings__btn webui-fo-settings__btn--solid"
            :disabled="!canSubmit"
            :title="validationErrors[0] ?? ''"
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

.webui-fo-settings__input--err {
  border-color: var(--webui-danger, #d83535);
}

.webui-fo-settings__input--err:focus {
  outline-color: var(--webui-danger, #d83535);
}

.webui-fo-settings__blurb {
  margin: 0;
  font-size: 0.85rem;
  line-height: 1.45;
  color: var(--webui-text);
  background: var(--webui-bg);
  border: 1px solid var(--webui-border);
  border-left: 3px solid var(--webui-accent);
  border-radius: 5px;
  padding: 0.55rem 0.75rem;
}

.webui-fo-settings__field-help {
  font-size: 0.78rem;
  line-height: 1.4;
  color: var(--webui-text-muted);
  margin-top: 0.15rem;
}

.webui-fo-settings__field-help code,
.webui-fo-settings__blurb code {
  font-family: var(--webui-font-mono);
  font-size: 0.75rem;
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
  align-items: center;
  justify-content: flex-end;
  gap: 0.5rem;
  border-top: 1px solid var(--webui-border);
}

.webui-fo-settings__foot-hint {
  margin: 0 auto 0 0;
  font-size: 0.78rem;
  color: var(--webui-danger, #d83535);
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
