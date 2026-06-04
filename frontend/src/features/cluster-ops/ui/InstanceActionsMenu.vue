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
import Button from 'primevue/button';
import { useToast } from 'primevue/usetoast';

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
const toast = useToast();
const expelOpen = ref(false);

// Backend action messages can be long ("manual override appointment
// written for tt-3 on rs-1 (expires in 300s). box.ctl.promote() ok.")
// — far too wide for the inline actions cell — so results surface as a
// corner toast instead. Successes auto-dismiss; failures stay until the
// operator dismisses them.
function notify(ok: boolean, summary: string, detail: string) {
  toast.add({
    severity: ok ? 'success' : 'error',
    summary,
    detail,
    life: ok ? 5000 : undefined,
  });
}

async function doPromote() {
  const r = await ops.promoteInstance(props.alias, { ttlSec: 300 });
  notify(r.ok, r.ok ? 'Promoted' : 'Promote failed', r.message);
  if (r.ok) emit('changed');
}

async function doToggleEnabled() {
  // null/undefined → assume enabled; toggle the explicit flag.
  const next = props.disabled === true; // currently disabled → enable
  const r = await ops.setInstanceState(props.alias, { enabled: next });
  notify(r.ok, r.ok ? (next ? 'Enabled' : 'Disabled') : 'Update failed', r.message);
  if (r.ok) emit('changed');
}

async function onExpelConfirm() {
  const r = await ops.expelInstance(props.alias, false);
  notify(r.ok, r.ok ? 'Expelled' : 'Expel failed', r.message);
  expelOpen.value = false;
  if (r.ok) emit('changed');
}
</script>

<template>
  <div class="webui-instance-actions">
    <Button
      label="Promote"
      size="small"
      outlined
      :disabled="ops.pending || isLeader"
      :title="
        isLeader
          ? 'already the configured leader'
          : 'promote to leader for 5 min (supervised override)'
      "
      @click="doPromote"
    />
    <Button
      :label="disabled ? 'Enable' : 'Disable'"
      size="small"
      outlined
      :disabled="ops.pending"
      :title="
        disabled
          ? 're-enable in agent score map'
          : 'mark disabled — agent stops considering it for promotion'
      "
      @click="doToggleEnabled"
    />
    <Button
      label="Expel…"
      size="small"
      severity="danger"
      outlined
      :disabled="ops.pending"
      @click="expelOpen = true"
    />
    <DestructiveActionDialog
      :open="expelOpen"
      title="Expel instance"
      :description="
        'Removes ' +
        alias +
        ' from cluster YAML and deletes its row in ' +
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
  flex-wrap: nowrap;
}
</style>
