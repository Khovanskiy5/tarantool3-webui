<script setup lang="ts">
/**
 * Failover settings modal.
 *
 * Wraps the backend's `setFailoverMode` mutation behind a per-mode
 * form. Each of the four modes drives leadership through a different
 * mechanism — the dialog reveals only the knobs that apply to the
 * selected mode and gates the Apply button on client-side validation
 * that mirrors the backend rules. The operator never sees an Apply
 * button they cannot use.
 *
 * `off` and `supervised` map to the same Tarantool YAML field but
 * mean different things to the operator. The dialog treats them as
 * MUTUALLY EXCLUSIVE effective modes:
 *
 *   * `off`        → `replication.failover: off, agent: false`
 *                    no automatic failover at all
 *   * `supervised` → `replication.failover: off, agent: true`
 *                    community agent runs the failover loop
 *
 * The previous design exposed both a `supervised` mode AND a
 * "Enable agent" checkbox inside `off` mode. That meant two UI paths
 * to the same YAML state and the dialog would open with the dropdown
 * showing `off` even when the agent was active — confusing for a
 * newcomer. Now there is exactly one path to each state and the
 * dropdown reflects the effective behaviour (off+agent → supervised).
 */
import { computed, nextTick, ref, watch } from 'vue';
import Button from 'primevue/button';
import Dialog from 'primevue/dialog';
import Fluid from 'primevue/fluid';
import InputNumber from 'primevue/inputnumber';
import InputText from 'primevue/inputtext';
import Message from 'primevue/message';
import Select from 'primevue/select';

import { useClusterOpsStore } from '../model/store';

const props = defineProps<{
  open: boolean;
  /** Current cluster-wide mode (`replication.failover`). */
  initialMode: string;
  /** Server count for the N/2+1 quorum hint. */
  instanceCount: number;
  /**
   * Whether the community supervised agent is currently running.
   * Combined with `initialMode` to compute the effective mode shown
   * in the dropdown: `off + agent` is presented as `supervised`.
   */
  initialAgentEnabled?: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void;
  (e: 'applied'): void;
}>();

const ops = useClusterOpsStore();

type Mode = 'off' | 'manual' | 'election' | 'supervised';
const VALID_MODES: Mode[] = ['off', 'manual', 'election', 'supervised'];

const MODE_OPTIONS: { value: Mode; label: string }[] = [
  { value: 'off', label: 'off — no automatic failover' },
  { value: 'manual', label: 'manual — static leader in YAML' },
  { value: 'election', label: 'election — built-in Raft' },
  { value: 'supervised', label: 'supervised — community agent (CE)' },
];

interface ModeBlurb {
  what: string;
  recommended: string;
}
const MODE_BLURB: Record<Mode, ModeBlurb> = {
  off: {
    what:
      'No automatic failover. Each instance follows its own database.mode; the WebUI ' +
      'community agent is disabled. If the current leader dies, the cluster stays read-only ' +
      'until an operator promotes someone manually.',
    recommended:
      'Advanced setups where leadership is driven by external orchestration ' +
      '(another agent, manual scripts, etc.). For typical CE clusters pick supervised instead.',
  },
  manual: {
    what:
      'Leader per replicaset is named statically by the `leader` field in the cluster YAML. ' +
      'No automatic failover — switching the leader is a config edit + commit.',
    recommended:
      'Small dev clusters or scheduled-maintenance scenarios where you want full control over ' +
      'who is RW and there is no need to recover automatically.',
  },
  election: {
    what:
      'Tarantool elects a leader per replicaset using its built-in Raft protocol. ' +
      'Election is fully automatic; the community agent does not run.',
    recommended:
      'Production clusters with at least 3 voting instances per replicaset. Best fit when ' +
      'you trust Raft and want zero external dependencies (no etcd needed for failover).',
  },
  supervised: {
    what:
      'The bundled community agent runs an open-source equivalent of Enterprise supervised. ' +
      'Every peer races for an etcd lease, the winner becomes coordinator and writes ' +
      "per-replicaset appointments to etcd; every peer's watcher reads its replicaset's " +
      'appointment and reconciles box.cfg.read_only accordingly.',
    recommended:
      'Production CE clusters (any size, including 2 nodes) when you already have etcd ' +
      'around. Survives the loss of one peer without manual intervention.',
  },
};

const FENCING_OPTIONS = [
  { value: '', label: '(keep current)' },
  { value: 'off', label: 'off — never demote' },
  { value: 'soft', label: 'soft — demote on quorum loss' },
  { value: 'strict', label: 'strict — soft + block stale reads' },
];

// Form state. Empty strings / nulls mean "do not touch" — the
// backend keeps the current cluster value for any unset knob.
const mode = ref<Mode>('off');
const synchroQuorum = ref<string>('');
const synchroTimeout = ref<number | null>(null);
const electionTimeout = ref<number | null>(null);
const electionFencing = ref<'' | 'off' | 'soft' | 'strict'>('');
const leaseTtlSec = ref<number | null>(null);

const banner = ref<{ severity: 'success' | 'error' | 'info'; text: string } | null>(null);
const diffSummary = ref<string[] | null>(null);

const visible = computed({
  get: () => props.open,
  set: (v) => emit('update:open', v),
});

// ── effective initial mode (off + agent → supervised) ───────────────
const effectiveInitialMode = computed<Mode>(() => {
  const m = VALID_MODES.includes(props.initialMode as Mode) ? (props.initialMode as Mode) : 'off';
  if (m === 'off' && props.initialAgentEnabled === true) return 'supervised';
  return m;
});

const isCurrentMode = computed(() => mode.value === effectiveInitialMode.value);

// ── validation ──────────────────────────────────────────────────────
const quorumFloor = computed(() =>
  props.instanceCount > 1 ? Math.floor(props.instanceCount / 2) + 1 : 1,
);

const synchroQuorumError = computed<string | null>(() => {
  const v = synchroQuorum.value.trim();
  if (v === '') return null;
  if (/^N\s*\/\s*2\s*\+\s*1$/i.test(v)) return null;
  if (!/^\d+$/.test(v)) {
    return 'Must be a whole number or the formula N/2 + 1';
  }
  const n = Number(v);
  if (n < quorumFloor.value) {
    return (
      `Below the safe floor N/2+1 = ${quorumFloor.value}. ` +
      'Two partitions could both reach quorum and split-brain.'
    );
  }
  return null;
});

const synchroTimeoutError = computed<string | null>(() => {
  const v = synchroTimeout.value;
  if (v === null) return null;
  if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) {
    return 'Must be a positive number';
  }
  return null;
});

const electionTimeoutError = computed<string | null>(() => {
  if (mode.value !== 'election') return null;
  const v = electionTimeout.value;
  if (v === null) return null;
  if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) {
    return 'Must be a positive number';
  }
  return null;
});

const leaseTtlError = computed<string | null>(() => {
  if (mode.value !== 'supervised') return null;
  const v = leaseTtlSec.value;
  if (v === null) return null;
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 1) {
    return 'Must be a whole second, ≥ 1';
  }
  return null;
});

const modeError = computed<string | null>(() => {
  if (mode.value === 'election' && props.instanceCount > 0 && props.instanceCount < 3) {
    return (
      `Raft needs at least 3 voting instances; this cluster has ${props.instanceCount}. ` +
      'Add more peers, or pick supervised instead.'
    );
  }
  return null;
});

const validationErrors = computed<string[]>(() =>
  [
    modeError.value,
    synchroQuorumError.value,
    synchroTimeoutError.value,
    electionTimeoutError.value,
    leaseTtlError.value,
  ].filter((s): s is string => s !== null),
);

const canSubmit = computed(() => !ops.pending && validationErrors.value.length === 0);

// ── side-effects preview ────────────────────────────────────────────
// What the backend will silently change on top of the explicit knobs.
const sideEffects = computed<string[]>(() => {
  if (isCurrentMode.value) return [];
  const out: string[] = [];
  if (mode.value === 'election' || mode.value === 'supervised') {
    out.push('Strip per-instance database.mode (Tarantool forbids it in this mode).');
  }
  if (mode.value === 'election' || mode.value === 'manual') {
    out.push('Disable the community agent (it would fight Tarantool over read_only).');
  }
  if (mode.value === 'supervised' || mode.value === 'off') {
    // Either mode clears the static leader field if any replicaset has it.
    out.push('Clear static replicaset.leader fields (only manual mode uses them).');
  }
  if (mode.value === 'manual') {
    out.push(
      'Pick a leader per replicaset automatically if none is set — current writer first, ' +
        'then last agent appointment, otherwise alphabetical first.',
    );
  }
  if (mode.value === 'off') {
    out.push('Disable the community agent. No automatic recovery on failure.');
  }
  if (mode.value === 'supervised') {
    out.push('Enable the community agent (acquires an etcd lease and writes appointments).');
  }
  return out;
});

// ── reset on open ───────────────────────────────────────────────────
watch(
  () => props.open,
  async (now) => {
    if (now) {
      mode.value = effectiveInitialMode.value;
      synchroQuorum.value = '';
      synchroTimeout.value = null;
      electionTimeout.value = null;
      electionFencing.value = '';
      leaseTtlSec.value = null;
      banner.value = null;
      diffSummary.value = null;
      await nextTick();
    }
  },
);

// ── apply / preview ─────────────────────────────────────────────────
function buildParams(): Record<string, unknown> | null {
  if (validationErrors.value.length > 0) {
    banner.value = { severity: 'error', text: validationErrors.value[0] };
    return null;
  }
  const params: Record<string, unknown> = {};

  if (synchroQuorum.value.trim() !== '') {
    const v = synchroQuorum.value.trim();
    params.synchro_quorum = /^\d+$/.test(v) ? Number(v) : v;
  }
  if (synchroTimeout.value !== null) {
    params.synchro_timeout = synchroTimeout.value;
  }
  if (mode.value === 'election') {
    if (electionTimeout.value !== null) {
      params.election_timeout = electionTimeout.value;
    }
    if (electionFencing.value !== '') {
      params.election_fencing_mode = electionFencing.value;
    }
  }
  // Explicit agent flag for off / supervised — the backend defaults
  // to "on" for plain off, which is not what the operator picked
  // when they explicitly chose off here.
  if (mode.value === 'off') {
    params.agent = false;
  }
  if (mode.value === 'supervised') {
    params.agent = true;
    if (leaseTtlSec.value !== null) {
      params.agent_params = { lease_ttl_sec: leaseTtlSec.value };
    }
  }
  return params;
}

// Backend accepts the YAML failover field, not our effective mode.
// Pass `supervised` straight through; the backend resolver maps it
// to `failover: off + agent: true` on commit.
function modeForBackend(): string {
  return mode.value;
}

async function runPreview() {
  const params = buildParams();
  if (params === null) return;
  banner.value = null;
  const res = await ops.setFailoverMode(
    modeForBackend(),
    Object.keys(params).length === 0 ? null : params,
    false,
  );
  if (!res.ok) {
    banner.value = { severity: 'error', text: res.message };
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
    modeForBackend(),
    Object.keys(params).length === 0 ? null : params,
    true,
  );
  if (!res.ok) {
    banner.value = { severity: 'error', text: res.message };
    return;
  }
  banner.value = { severity: 'success', text: res.message };
  emit('applied');
  setTimeout(() => emit('update:open', false), 1200);
}

function onCancel() {
  if (ops.pending) return;
  emit('update:open', false);
}
</script>

<template>
  <Dialog
    v-model:visible="visible"
    modal
    header="Failover settings"
    :style="{ width: '38rem' }"
    :closable="!ops.pending"
    :close-on-escape="!ops.pending"
    @hide="onCancel"
  >
    <div class="fo-body">
      <Message size="small" severity="secondary" variant="simple">
        Choose how the cluster decides who is the read-write leader. Empty fields keep the current
        cluster value untouched.
      </Message>
      <Fluid>
        <!-- ── Mode picker ───────────────────────────────────────── -->
        <div class="r-field">
          <label for="fo-mode" class="fo-label-row">
            <span>Mode</span>
            <span v-if="isCurrentMode" class="fo-current">currently applied</span>
          </label>
          <Select
            v-model="mode"
            input-id="fo-mode"
            :options="MODE_OPTIONS"
            option-label="label"
            option-value="value"
          />
          <Message size="small" severity="info" variant="simple">
            <p class="fo-blurb-what">{{ MODE_BLURB[mode].what }}</p>
            <p class="fo-blurb-when">
              <strong>Recommended for:</strong> {{ MODE_BLURB[mode].recommended }}
            </p>
          </Message>
          <Message v-if="modeError" size="small" severity="error" variant="simple">
            {{ modeError }}
          </Message>
        </div>

        <!-- Side-effects (only when switching away from current) -->
        <Message v-if="sideEffects.length > 0" size="small" severity="warn" variant="simple">
          <p class="fo-effects-head">
            Switching to <code>{{ mode }}</code> will also:
          </p>
          <ul class="fo-effects-list">
            <li v-for="effect in sideEffects" :key="effect">{{ effect }}</li>
          </ul>
        </Message>

        <!-- ── Synchronous replication (shared) ──────────────────── -->
        <fieldset class="fo-group">
          <legend>Synchronous replication</legend>
          <div class="r-field">
            <label for="fo-quorum"> Write quorum <code class="fo-key">synchro_quorum</code> </label>
            <InputText
              id="fo-quorum"
              v-model="synchroQuorum"
              placeholder="N/2 + 1 (leave empty to keep current)"
              :invalid="!!synchroQuorumError"
              autocomplete="off"
            />
            <Message size="small" severity="info" variant="simple">
              Number of peers that must acknowledge a synchronous write before it commits. Safe
              floor is <code>N/2 + 1</code> ({{ quorumFloor }} for this {{ instanceCount }}-node
              cluster). Lower values let two partitions commit independently → split-brain. Accepts
              a number or the formula <code>N/2 + 1</code>.
            </Message>
            <Message v-if="synchroQuorumError" size="small" severity="error" variant="simple">
              {{ synchroQuorumError }}
            </Message>
          </div>
          <div class="r-field">
            <label for="fo-stimeout">
              Sync timeout <code class="fo-key">synchro_timeout</code> (sec)
            </label>
            <InputNumber
              v-model="synchroTimeout"
              input-id="fo-stimeout"
              :min="0"
              :min-fraction-digits="0"
              :max-fraction-digits="3"
              placeholder="3 (leave empty to keep current)"
              :invalid="!!synchroTimeoutError"
            />
            <Message size="small" severity="info" variant="simple">
              How long a sync write waits for quorum acks before it fails. Too low → flaky writes
              under network jitter. Too high → slow failure detection.
            </Message>
            <Message v-if="synchroTimeoutError" size="small" severity="error" variant="simple">
              {{ synchroTimeoutError }}
            </Message>
          </div>
        </fieldset>

        <!-- ── Election (mode=election only) ─────────────────────── -->
        <fieldset v-if="mode === 'election'" class="fo-group">
          <legend>Raft election</legend>
          <div class="r-field">
            <label for="fo-etimeout">
              Election timeout <code class="fo-key">election_timeout</code> (sec)
            </label>
            <InputNumber
              v-model="electionTimeout"
              input-id="fo-etimeout"
              :min="0"
              :min-fraction-digits="0"
              :max-fraction-digits="3"
              placeholder="5 (leave empty to keep current)"
              :invalid="!!electionTimeoutError"
            />
            <Message size="small" severity="info" variant="simple">
              How long a follower waits without leader heartbeats before starting a vote. Lower →
              faster failover; too low → false elections during transient jitter.
            </Message>
            <Message v-if="electionTimeoutError" size="small" severity="error" variant="simple">
              {{ electionTimeoutError }}
            </Message>
          </div>
          <div class="r-field">
            <label for="fo-fencing">
              Fencing <code class="fo-key">election_fencing_mode</code>
            </label>
            <Select
              v-model="electionFencing"
              input-id="fo-fencing"
              :options="FENCING_OPTIONS"
              option-label="label"
              option-value="value"
              placeholder="(keep current)"
            />
            <Message size="small" severity="info" variant="simple">
              What an isolated leader does when it loses quorum. <code>soft</code> demotes on quorum
              loss; <code>strict</code> also blocks reads from the isolated peer.
            </Message>
          </div>
        </fieldset>

        <!-- ── Agent parameters (mode=supervised only) ───────────── -->
        <fieldset v-if="mode === 'supervised'" class="fo-group">
          <legend>Community agent parameters</legend>
          <div class="r-field">
            <label for="fo-lease">
              Lease TTL <code class="fo-key">lease_ttl_sec</code> (sec)
            </label>
            <InputNumber
              v-model="leaseTtlSec"
              input-id="fo-lease"
              :min="1"
              :step="1"
              placeholder="3 (leave empty to keep current)"
              :invalid="!!leaseTtlError"
            />
            <Message size="small" severity="info" variant="simple">
              How long the coordinator's etcd lease lives between keep-alives. Lower → faster
              re-election when the coordinator dies, but more etcd load. Whole seconds, ≥ 1.
            </Message>
            <Message v-if="leaseTtlError" size="small" severity="error" variant="simple">
              {{ leaseTtlError }}
            </Message>
          </div>
        </fieldset>

        <!-- ── Diff preview / outcome banner ─────────────────────── -->
        <Message
          v-if="diffSummary && diffSummary.length > 0"
          size="small"
          severity="info"
          variant="simple"
        >
          <p class="fo-diff-head">
            <strong
              >Diff ({{ diffSummary.length }} op{{ diffSummary.length === 1 ? '' : 's' }}):</strong
            >
          </p>
          <ul class="fo-diff-list">
            <li v-for="(op, idx) in diffSummary" :key="idx">
              <code>{{ op }}</code>
            </li>
          </ul>
        </Message>
        <Message v-if="banner" size="small" :severity="banner.severity" variant="simple">
          {{ banner.text }}
        </Message>
      </Fluid>
    </div>
    <template #footer>
      <Message
        v-if="validationErrors.length > 0"
        severity="error"
        variant="simple"
        size="small"
        class="fo-foot-hint"
      >
        Fix the highlighted fields to enable Apply.
      </Message>
      <Button label="Cancel" severity="secondary" text :disabled="ops.pending" @click="onCancel" />
      <Button
        label="Preview"
        icon="pi pi-eye"
        severity="secondary"
        :disabled="!canSubmit"
        @click="runPreview"
      />
      <Button
        label="Apply"
        icon="pi pi-check"
        :loading="ops.pending"
        :disabled="!canSubmit"
        @click="runApply"
      />
    </template>
  </Dialog>
</template>

<style scoped>
.fo-body {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.fo-body :deep(.p-fluid) {
  display: flex;
  flex-direction: column;
  gap: 1.1rem;
}
.r-field {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  min-width: 0;
}
.r-field > label {
  font-size: 0.88rem;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.fo-label-row {
  justify-content: space-between;
}
.fo-current {
  font-size: 0.72rem;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding: 0.1rem 0.5rem;
  border-radius: 999px;
  background: var(--p-primary-color, var(--webui-accent));
  color: var(--p-primary-contrast-color, #0e1117);
}
.fo-key {
  font-family: var(--webui-font-mono, monospace);
  font-size: 0.78rem;
  font-weight: 500;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.fo-group {
  border: 1px solid var(--p-content-border-color, var(--webui-border));
  border-radius: var(--p-content-border-radius, 6px);
  padding: 0.85rem 1rem 1rem;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
}
.fo-group > legend {
  font-size: 0.72rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--p-text-muted-color, var(--webui-text-muted));
  padding: 0 0.4rem;
}
.fo-blurb-what {
  margin: 0;
}
.fo-blurb-when {
  margin: 0.4rem 0 0;
}
.fo-effects-head {
  margin: 0 0 0.4rem;
}
.fo-effects-list,
.fo-diff-list {
  margin: 0;
  padding-left: 1.2rem;
}
.fo-effects-list li,
.fo-diff-list li {
  margin-bottom: 0.15rem;
}
.fo-diff-head {
  margin: 0 0 0.3rem;
}
.fo-foot-hint {
  margin: 0 auto 0 0;
}
:deep(.p-message-text code),
:deep(.fo-blurb-what code),
:deep(.fo-blurb-when code) {
  font-family: var(--webui-font-mono, monospace);
  font-size: 0.78rem;
}
</style>
