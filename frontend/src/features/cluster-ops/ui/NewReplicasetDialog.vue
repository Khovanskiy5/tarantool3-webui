<script setup lang="ts">
/**
 * "New replicaset" modal (Phase 5 Task 5.18).
 *
 * Composes a single TopologyEdit through the backend's
 * `createReplicaset` alias. The dev cluster does not yet support
 * the "pick unassigned instances" affordance Cartridge had — all
 * Tarantool 3.x instances are bound to their replicaset in cluster
 * YAML — so we expose the closest pragmatic equivalent: an
 * operator-supplied instance spec map. The shape mirrors what the
 * backend resolver expects, and the type-aware preview + apply
 * cycle catches typos before they reach etcd.
 *
 * Flow:
 *   1. Operator fills name + group + instances + optional knobs.
 *   2. "Preview" → createReplicaset(apply=false). The backend
 *      assembles the new YAML, validates it, and returns a
 *      diff_summary; we render the list and switch the primary
 *      action to "Apply".
 *   3. "Apply" → createReplicaset(apply=true). On success the
 *      modal closes and emits `created` so the parent refreshes
 *      its snapshot.
 *
 * The modal lives behind the same dark-theme primitives as
 * DestructiveActionDialog; it stays mounted via Teleport so the
 * cluster page chrome cannot steal focus.
 */
import { computed, nextTick, ref, watch } from 'vue';

import { useClusterOpsStore } from '../model/store';

const props = defineProps<{
  open: boolean;
}>();

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'created'): void;
}>();

const ops = useClusterOpsStore();

// Form state — kept light because the heavy lifting (schema +
// cross-validation) happens on the backend. We surface error /
// preview message verbatim so the operator always sees what the
// cluster sees.
const name = ref('');
const group = ref('default');
const instancesText = ref(
  // Helpful starting point: the same instance shape the backend
  // already knows about from `groups.<g>.replicasets.<rs>.instances.<alias>`.
  '{\n  "tt-new": {\n    "iproto": {\n      "advertise": { "peer": { "uri": "tt-new:3301" } },\n      "listen": [{ "uri": "0.0.0.0:3301" }]\n    },\n    "database": { "mode": "rw" }\n  }\n}',
);
const leader = ref('');
const rolesText = ref('');
const weightText = ref('');
const vshardGroup = ref('');

const banner = ref<{ severity: 'ok' | 'err' | 'info'; text: string } | null>(null);
const diffSummary = ref<string[] | null>(null);
const namedInput = ref<HTMLInputElement | null>(null);

watch(
  () => props.open,
  async (now) => {
    if (now) {
      banner.value = null;
      diffSummary.value = null;
      await nextTick();
      namedInput.value?.focus();
    }
  },
);

const canSubmit = computed(
  () => name.value.trim() !== '' && group.value.trim() !== '' && !ops.pending,
);

function buildPayload(apply: boolean): Record<string, unknown> | null {
  // Instance spec: parse the JSON the operator typed. We catch the
  // parse error here so the modal stays open and surfaces a clear
  // line/column hint instead of letting the GraphQL layer reject
  // with the more generic VALIDATION_ERROR.
  let instances: Record<string, unknown> | undefined;
  if (instancesText.value.trim() !== '') {
    try {
      const parsed = JSON.parse(instancesText.value);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        banner.value = {
          severity: 'err',
          text: 'instances must be a JSON object keyed by alias',
        };
        return null;
      }
      instances = parsed as Record<string, unknown>;
    } catch (err) {
      banner.value = {
        severity: 'err',
        text: `instances JSON: ${(err as Error).message}`,
      };
      return null;
    }
  }

  // roles + failover_priority are CSV-friendly so the operator can
  // type them in one line.
  const roles = rolesText.value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '');

  const weight = weightText.value.trim() === ''
    ? undefined
    : Number(weightText.value);
  if (weight !== undefined && (Number.isNaN(weight) || weight < 0)) {
    banner.value = {
      severity: 'err',
      text: 'weight must be a non-negative number',
    };
    return null;
  }

  const payload: Record<string, unknown> = {
    name: name.value.trim(),
    group: group.value.trim(),
    apply,
  };
  if (instances !== undefined) payload.instances = instances;
  if (roles.length > 0) payload.roles = roles;
  if (leader.value.trim() !== '') payload.leader = leader.value.trim();
  if (weight !== undefined) payload.weight = weight;
  if (vshardGroup.value.trim() !== '') payload.vshard_group = vshardGroup.value.trim();
  return payload;
}

async function runPreview() {
  const payload = buildPayload(false);
  if (payload === null) return;
  banner.value = null;
  const res = await ops.createReplicaset(payload);
  if (!res.ok) {
    banner.value = { severity: 'err', text: res.message };
    diffSummary.value = null;
    return;
  }
  diffSummary.value = res.diffSummary ?? [];
  banner.value = {
    severity: 'info',
    text: `Preview ok — ${diffSummary.value.length} op(s) ready. Press Apply to commit.`,
  };
}

async function runApply() {
  const payload = buildPayload(true);
  if (payload === null) return;
  banner.value = null;
  const res = await ops.createReplicaset(payload);
  if (!res.ok) {
    banner.value = { severity: 'err', text: res.message };
    return;
  }
  banner.value = { severity: 'ok', text: res.message };
  emit('created');
  // Close after a short pause so the operator can read the
  // confirmation banner.
  setTimeout(() => emit('close'), 1200);
}

function onCancel() {
  if (ops.pending) return;
  emit('close');
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="webui-new-rs">
      <div class="webui-new-rs__backdrop" @click="onCancel" />
      <div
        class="webui-new-rs__panel"
        role="dialog"
        aria-modal="true"
      >
        <header class="webui-new-rs__head">
          <h2 class="webui-new-rs__title">New replicaset</h2>
          <p class="webui-new-rs__hint">
            Routes through <code>createReplicaset</code> — schema-
            validates the assembled YAML before touching etcd.
          </p>
        </header>
        <div class="webui-new-rs__body">
          <div class="webui-new-rs__row">
            <label class="webui-new-rs__field">
              Name
              <input
                ref="namedInput"
                v-model="name"
                type="text"
                autocomplete="off"
                spellcheck="false"
                class="webui-new-rs__input"
                placeholder="rs-2"
              >
            </label>
            <label class="webui-new-rs__field">
              Group
              <input
                v-model="group"
                type="text"
                autocomplete="off"
                spellcheck="false"
                class="webui-new-rs__input"
                placeholder="default"
              >
            </label>
          </div>
          <label class="webui-new-rs__field">
            Instances (JSON map keyed by alias)
            <textarea
              v-model="instancesText"
              class="webui-new-rs__textarea"
              rows="9"
              spellcheck="false"
            />
          </label>
          <div class="webui-new-rs__row">
            <label class="webui-new-rs__field">
              Leader (alias from instances)
              <input
                v-model="leader"
                type="text"
                autocomplete="off"
                spellcheck="false"
                class="webui-new-rs__input"
                placeholder="tt-new"
              >
            </label>
            <label class="webui-new-rs__field">
              Weight
              <input
                v-model="weightText"
                type="number"
                min="0"
                step="0.1"
                class="webui-new-rs__input"
                placeholder="1"
              >
            </label>
          </div>
          <div class="webui-new-rs__row">
            <label class="webui-new-rs__field">
              Roles (comma-separated)
              <input
                v-model="rolesText"
                type="text"
                autocomplete="off"
                spellcheck="false"
                class="webui-new-rs__input"
                placeholder="vshard-storage, app.roles.storage"
              >
            </label>
            <label class="webui-new-rs__field">
              vshard_group
              <input
                v-model="vshardGroup"
                type="text"
                autocomplete="off"
                spellcheck="false"
                class="webui-new-rs__input"
                placeholder="hot"
              >
            </label>
          </div>
          <div
            v-if="diffSummary && diffSummary.length > 0"
            class="webui-new-rs__diff"
          >
            <strong>Diff ({{ diffSummary.length }} op{{ diffSummary.length === 1 ? '' : 's' }}):</strong>
            <ul>
              <li v-for="(op, idx) in diffSummary" :key="idx">
                <code>{{ op }}</code>
              </li>
            </ul>
          </div>
          <p
            v-if="banner"
            :class="[
              'webui-new-rs__msg',
              banner.severity === 'err'
                ? 'webui-new-rs__msg--err'
                : banner.severity === 'info'
                  ? 'webui-new-rs__msg--info'
                  : 'webui-new-rs__msg--ok',
            ]"
          >
            {{ banner.text }}
          </p>
        </div>
        <footer class="webui-new-rs__foot">
          <button
            type="button"
            class="webui-new-rs__btn"
            :disabled="ops.pending"
            @click="onCancel"
          >
            Cancel
          </button>
          <button
            type="button"
            class="webui-new-rs__btn"
            :disabled="!canSubmit"
            @click="runPreview"
          >
            Preview
          </button>
          <button
            type="button"
            class="webui-new-rs__btn webui-new-rs__btn--solid"
            :disabled="!canSubmit"
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
.webui-new-rs {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.webui-new-rs__backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
}

.webui-new-rs__panel {
  position: relative;
  width: min(640px, 94vw);
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

.webui-new-rs__head {
  padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--webui-border);
}

.webui-new-rs__title {
  margin: 0 0 0.25rem 0;
  font-size: 1.05rem;
  font-weight: 600;
  color: var(--webui-text);
}

.webui-new-rs__hint {
  margin: 0;
  font-size: 0.82rem;
  color: var(--webui-text-muted);
}

.webui-new-rs__hint code {
  font-family: var(--webui-font-mono);
}

.webui-new-rs__body {
  padding: 1rem 1.25rem;
  display: flex;
  flex-direction: column;
  gap: 0.85rem;
}

.webui-new-rs__row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.85rem;
}

.webui-new-rs__field {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  font-size: 0.85rem;
  color: var(--webui-text-muted);
}

.webui-new-rs__input {
  font-family: var(--webui-font-mono);
  font-size: 0.9rem;
  padding: 0.4rem 0.55rem;
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  background: var(--webui-bg);
  color: var(--webui-text);
}

.webui-new-rs__textarea {
  font-family: var(--webui-font-mono);
  font-size: 0.82rem;
  padding: 0.5rem 0.6rem;
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  background: var(--webui-bg);
  color: var(--webui-text);
  resize: vertical;
  min-height: 100px;
}

.webui-new-rs__input:focus,
.webui-new-rs__textarea:focus {
  outline: 2px solid var(--webui-accent);
  outline-offset: -1px;
}

.webui-new-rs__diff {
  font-size: 0.85rem;
  background: var(--webui-bg);
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  padding: 0.6rem 0.85rem;
}

.webui-new-rs__diff ul {
  margin: 0.4rem 0 0;
  padding-left: 1.2rem;
}

.webui-new-rs__diff code {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
  color: var(--webui-text-muted);
}

.webui-new-rs__msg {
  margin: 0;
  font-size: 0.85rem;
  padding: 0.4rem 0.65rem;
  border-radius: 4px;
  border: 1px solid transparent;
}

.webui-new-rs__msg--ok {
  background: rgba(63, 185, 80, 0.12);
  border-color: rgba(63, 185, 80, 0.4);
  color: var(--webui-success);
}

.webui-new-rs__msg--info {
  background: rgba(78, 168, 222, 0.12);
  border-color: rgba(78, 168, 222, 0.4);
  color: var(--webui-accent);
}

.webui-new-rs__msg--err {
  background: rgba(248, 81, 73, 0.12);
  border-color: rgba(248, 81, 73, 0.4);
  color: var(--webui-danger);
}

.webui-new-rs__foot {
  padding: 0.85rem 1.25rem;
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  border-top: 1px solid var(--webui-border);
}

.webui-new-rs__btn {
  padding: 0.5rem 1rem;
  font-size: 0.92rem;
  border-radius: 5px;
  cursor: pointer;
  border: 1px solid var(--webui-border);
  background: var(--webui-bg);
  color: var(--webui-text);
  font-weight: 500;
}

.webui-new-rs__btn:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}

.webui-new-rs__btn:disabled {
  cursor: not-allowed;
  opacity: 0.4;
}

.webui-new-rs__btn--solid {
  background: var(--webui-accent);
  color: #0e1117;
  border-color: var(--webui-accent);
}

.webui-new-rs__btn--solid:not(:disabled):hover {
  background: #6cb8e3;
  border-color: #6cb8e3;
  color: #0e1117;
}
</style>
