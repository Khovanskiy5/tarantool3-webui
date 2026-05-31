<script setup lang="ts">
/**
 * Per-instance action menu (Phase 5 minimal slice).
 *
 * Renders three buttons:
 *   * Promote — manual override; supervised mode writes
 *     `manual_override_until` so the agent stops auto-electing.
 *   * Disable / Enable — toggle through setInstanceState; the
 *     supervised path lands in etcd `<prefix>/failover/disabled/<alias>`.
 *   * Expel… — opens the type-to-confirm dialog before calling
 *     expelInstance; rejected on the last instance unless forced.
 *
 * The component is deliberately ungrouped (no 3-dot menu) so a
 * single click does not hide destructive actions behind a popup —
 * matches the rest of the SPA's affordance style.
 */
import { ref } from 'vue';

import { DestructiveActionDialog } from '@/shared/ui/destructive-action-dialog';

import { useClusterOpsStore } from '../model/store';

const props = defineProps<{
  alias: string;
  /** When known, lets us mark "current leader" actions differently. */
  isLeader?: boolean;
  /** Surfaced from setInstanceState writes. Null = unknown. */
  disabled?: boolean | null;
}>();

const emit = defineEmits<{
  (e: 'changed'): void;
}>();

const ops = useClusterOpsStore();
const banner = ref<{ severity: 'ok' | 'err'; text: string } | null>(null);
const expelOpen = ref(false);

function setBanner(ok: boolean, text: string) {
  banner.value = { severity: ok ? 'ok' : 'err', text };
}

async function doPromote() {
  const r = await ops.promoteInstance(props.alias, { ttlSec: 300 });
  setBanner(r.ok, r.message);
  if (r.ok) emit('changed');
}

async function doToggleEnabled() {
  // null/undefined → assume enabled; toggle the explicit flag.
  const next = props.disabled === true; // currently disabled → enable
  const r = await ops.setInstanceState(props.alias, { enabled: next });
  setBanner(r.ok, r.message);
  if (r.ok) emit('changed');
}

async function onExpelConfirm() {
  const r = await ops.expelInstance(props.alias, false);
  setBanner(r.ok, r.message);
  expelOpen.value = false;
  if (r.ok) emit('changed');
}
</script>

<template>
  <div class="webui-instance-actions">
    <button
      type="button"
      class="webui-instance-actions__btn"
      :disabled="ops.pending || isLeader"
      :title="
        isLeader
          ? 'already the configured leader'
          : 'promote to leader for 5 min (supervised override)'
      "
      @click="doPromote"
    >
      Promote
    </button>
    <button
      type="button"
      class="webui-instance-actions__btn"
      :disabled="ops.pending"
      :title="
        disabled
          ? 're-enable in agent score map'
          : 'mark disabled — agent stops considering it for promotion'
      "
      @click="doToggleEnabled"
    >
      {{ disabled ? 'Enable' : 'Disable' }}
    </button>
    <button
      type="button"
      class="webui-instance-actions__btn webui-instance-actions__btn--danger"
      :disabled="ops.pending"
      @click="expelOpen = true"
    >
      Expel…
    </button>
    <p
      v-if="banner"
      :class="[
        'webui-instance-actions__msg',
        banner.severity === 'err'
          ? 'webui-instance-actions__msg--err'
          : 'webui-instance-actions__msg--ok',
      ]"
    >
      {{ banner.text }}
    </p>
    <DestructiveActionDialog
      :open="expelOpen"
      title="Expel instance"
      :description="
        'Removes ' + alias + ' from cluster YAML and deletes its row in ' +
          '_cluster on every reachable peer. Data on the expelled host stays ' +
          'in place — rebalance vshard buckets manually before decommissioning.'
      "
      :expected="alias"
      :prompt="`Type the instance alias (${alias}) to confirm:`"
      confirm-label="Expel"
      :pending="ops.pending"
      @cancel="expelOpen = false"
      @confirm="onExpelConfirm"
    />
  </div>
</template>

<style scoped>
.webui-instance-actions {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  flex-wrap: wrap;
}

.webui-instance-actions__btn {
  padding: 0.25rem 0.6rem;
  font-size: 0.78rem;
  border-radius: 4px;
  border: 1px solid var(--webui-border);
  background: var(--webui-bg);
  color: var(--webui-text);
  cursor: pointer;
}

.webui-instance-actions__btn:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}

.webui-instance-actions__btn:disabled {
  cursor: not-allowed;
  opacity: 0.35;
}

.webui-instance-actions__btn--danger {
  color: var(--webui-danger);
  border-color: rgba(248, 81, 73, 0.5);
}

.webui-instance-actions__btn--danger:not(:disabled):hover {
  border-color: var(--webui-danger);
  color: var(--webui-danger);
  background: rgba(248, 81, 73, 0.08);
}

.webui-instance-actions__msg {
  flex-basis: 100%;
  margin: 0.25rem 0 0 0;
  font-size: 0.75rem;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  border: 1px solid transparent;
}

.webui-instance-actions__msg--ok {
  background: rgba(63, 185, 80, 0.1);
  border-color: rgba(63, 185, 80, 0.3);
  color: var(--webui-success);
}

.webui-instance-actions__msg--err {
  background: rgba(248, 81, 73, 0.1);
  border-color: rgba(248, 81, 73, 0.3);
  color: var(--webui-danger);
}
</style>
