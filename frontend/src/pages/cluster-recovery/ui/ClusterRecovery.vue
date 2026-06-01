<!--
  /cluster-recovery — DR diagnostics + wizards.

  Two cards in the MVP:
    * Diagnostic table — one row per peer with role/status/last_lsn
      and a colour-coded chip ("queue-owner" green, "follower" muted,
      "split-brain" red, "orphan" amber, "unreachable" grey).
    * Active issue card — shows the high-level recommendation
      (split_brain_resolve / leader_takeover / no_action_needed)
      with the matching wizard button.

  Each wizard collects the inputs it needs (winner + losers for
  split-brain; target for takeover), goes through the existing
  DestructiveActionDialog for type-to-confirm, then fires
  `recoveryAction(...)`. Streaming progress is post-MVP — the
  resolver returns the per-peer outcome synchronously.
-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Message from 'primevue/message';
import Select from 'primevue/select';
import MultiSelect from 'primevue/multiselect';
import Dialog from 'primevue/dialog';

import { getClient } from '@/shared/api/graphql';

interface PeerEntry {
  alias: string;
  uuid: string | null;
  replicaset: string | null;
  role: string;
  status: string | null;
  ro: boolean | null;
  reachable: boolean | null;
  last_lsn: number | null;
  current_term: number | null;
  queue_owner: boolean | null;
  reasons: string[];
}

interface SplitBrainGroup {
  divergent_from: string | null;
  members: string[];
}

interface RecoverySnapshot {
  self_alias: string | null;
  generation: number | null;
  recommendation: string;
  peers: PeerEntry[];
  split_brain_groups: SplitBrainGroup[];
}

interface ActionResult {
  ok: boolean;
  action: string;
  error?: string | null;
  results: { peer: string; ok: boolean; msg: string | null }[];
}

const SNAPSHOT_Q = /* GraphQL */ `
  query DrSnapshot {
    recoverySnapshot {
      self_alias generation recommendation
      peers {
        alias uuid replicaset role status ro reachable
        last_lsn current_term queue_owner reasons
      }
      split_brain_groups { divergent_from members }
    }
  }
`;

const ACTION_M = /* GraphQL */ `
  mutation DrAction($action: String!, $payload: String) {
    recoveryAction(action: $action, payload: $payload) {
      ok action error
      results { peer ok msg }
    }
  }
`;

const loading = ref(false);
const snapshot = ref<RecoverySnapshot | null>(null);
const error = ref<string | null>(null);
const lastResult = ref<ActionResult | null>(null);

async function refresh() {
  loading.value = true;
  error.value = null;
  try {
    const res = await getClient()
      .query<{ recoverySnapshot: RecoverySnapshot }>(
        SNAPSHOT_Q, {}, { requestPolicy: 'network-only' })
      .toPromise();
    if (res.error) {
      error.value = res.error.message;
      return;
    }
    snapshot.value = res.data?.recoverySnapshot ?? null;
  } finally {
    loading.value = false;
  }
}

onMounted(refresh);

const peerRoleSeverity = (role: string) => {
  if (role === 'queue-owner') return 'success';
  if (role === 'split-brain') return 'danger';
  if (role === 'orphan') return 'warn';
  if (role === 'unreachable') return 'secondary';
  return 'info';
};

// ── Split-brain wizard ────────────────────────────────────────────

const sbOpen = ref(false);
const sbWinner = ref<string>('');
const sbLosers = ref<string[]>([]);
const sbAction = ref<'rebootstrap_losing' | 'force_promote_winner' | 'manual'>('rebootstrap_losing');
const sbConfirm = ref('');
const sbBusy = ref(false);

const splitBrainPeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter((p) => p.role === 'split-brain');
});

const healthyPeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter(
    (p) => p.role === 'queue-owner' || p.role === 'follower',
  );
});

function openSplitBrainWizard() {
  sbOpen.value = true;
  sbWinner.value = healthyPeers.value.find((p) => p.queue_owner)?.alias
    ?? healthyPeers.value[0]?.alias ?? '';
  sbLosers.value = splitBrainPeers.value.map((p) => p.alias);
  sbAction.value = 'rebootstrap_losing';
  sbConfirm.value = '';
}

const sbConfirmExpected = computed(() => `SPLIT BRAIN ${sbWinner.value}`);

async function executeSplitBrain() {
  if (sbConfirm.value.trim() !== sbConfirmExpected.value) return;
  sbBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'split_brain_resolve',
      payload: JSON.stringify({
        action: sbAction.value,
        winner_alias: sbWinner.value,
        losing_aliases: sbLosers.value,
      }),
    })
    .toPromise();
  sbBusy.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  lastResult.value = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction ?? null;
  sbOpen.value = false;
  await refresh();
}

// ── Leader takeover wizard ────────────────────────────────────────

const ltOpen = ref(false);
const ltTarget = ref<string>('');
const ltConfirm = ref('');
const ltBusy = ref(false);

function openTakeoverWizard() {
  ltOpen.value = true;
  // Pick the peer with the highest LSN as the default candidate.
  const sorted = healthyPeers.value.slice().sort(
    (a, b) => (b.last_lsn ?? 0) - (a.last_lsn ?? 0),
  );
  ltTarget.value = sorted[0]?.alias ?? '';
  ltConfirm.value = '';
}

const ltConfirmExpected = computed(() => `TAKEOVER ${ltTarget.value}`);

async function executeTakeover() {
  if (ltConfirm.value.trim() !== ltConfirmExpected.value) return;
  ltBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'leader_takeover',
      payload: JSON.stringify({ target_alias: ltTarget.value }),
    })
    .toPromise();
  ltBusy.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  lastResult.value = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction ?? null;
  ltOpen.value = false;
  await refresh();
}

const peerOptions = computed(() =>
  (snapshot.value?.peers ?? []).map((p) => ({
    label: `${p.alias}${p.queue_owner ? ' · queue-owner' : ''}`,
    value: p.alias,
  })),
);

// ── Orphan wizard ─────────────────────────────────────────────────
const orOpen = ref(false);
const orTarget = ref<string>('');
const orAction = ref<'force_reconnect' | 'rebootstrap' | 'solo_promote'>('force_reconnect');
const orConfirm = ref('');
const orBusy = ref(false);

function openOrphanWizard() {
  orOpen.value = true;
  orTarget.value = (snapshot.value?.peers ?? [])
    .find((p) => p.role === 'orphan')?.alias ?? '';
  orAction.value = 'force_reconnect';
  orConfirm.value = '';
}

const orConfirmExpected = computed(() => `ORPHAN ${orTarget.value}`);

async function executeOrphan() {
  if (orConfirm.value.trim() !== orConfirmExpected.value) return;
  orBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'orphan_resolve',
      payload: JSON.stringify({
        target_alias: orTarget.value,
        action: orAction.value,
      }),
    })
    .toPromise();
  orBusy.value = false;
  if (res.error) { error.value = res.error.message; return; }
  lastResult.value = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction ?? null;
  orOpen.value = false;
  await refresh();
}

// ── Quorum loss wizard ────────────────────────────────────────────
const qOpen = ref(false);
const qTarget = ref<string>('');
const qWindow = ref<number>(300);
const qAck = ref(false);
const qConfirm = ref('');
const qBusy = ref(false);

function openQuorumWizard() {
  qOpen.value = true;
  qTarget.value = (snapshot.value?.peers ?? [])
    .find((p) => p.queue_owner)?.alias
    ?? (snapshot.value?.peers ?? [])[0]?.alias ?? '';
  qWindow.value = 300;
  qAck.value = false;
  qConfirm.value = '';
}

const qConfirmExpected = computed(() => `QUORUM ${qTarget.value}`);

async function executeQuorum() {
  if (qConfirm.value.trim() !== qConfirmExpected.value || !qAck.value) return;
  qBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'quorum_loss_escape',
      payload: JSON.stringify({
        target_alias: qTarget.value,
        window_sec: qWindow.value,
        risk_acknowledged: true,
      }),
    })
    .toPromise();
  qBusy.value = false;
  if (res.error) { error.value = res.error.message; return; }
  lastResult.value = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction ?? null;
  qOpen.value = false;
  await refresh();
}

// ── Topology fix wizard ───────────────────────────────────────────
interface TopologyPeer {
  alias: string;
  declared_uri: string | null;
  observed_uri: string | null;
  reachable: boolean;
  suggestion: string | null;
}
const tOpen = ref(false);
const tPeers = ref<TopologyPeer[]>([]);
const tFixes = ref<Record<string, string>>({});
const tConfirm = ref('');
const tBusy = ref(false);

async function openTopologyWizard() {
  tOpen.value = true;
  tConfirm.value = '';
  tBusy.value = false;
  // Use the diagnose pseudo-action — backend returns its
  // diagnostic via the standard recoveryAction shape so the
  // results array carries one row per peer with `msg` filled
  // when a fix is suggested.
  const diag = await getClient()
    .mutation(ACTION_M, {
      action: 'topology_fix_diagnose', payload: null,
    })
    .toPromise();
  const arr: TopologyPeer[] = [];
  const peers = ((diag.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction?.results) ?? [];
  for (const p of peers) {
    arr.push({
      alias: p.peer,
      declared_uri: null,
      observed_uri: null,
      reachable: p.ok,
      suggestion: p.ok ? null : p.msg,
    });
  }
  tPeers.value = arr;
  tFixes.value = {};
  for (const p of arr) {
    if (p.suggestion) {
      // suggestion msg currently encodes `declared=X observed=Y`
      // — pull the Y portion as the proposed value.
      const m = p.suggestion.match(/observed=(\S+)/);
      if (m) tFixes.value[p.alias] = m[1];
    }
  }
}

const tConfirmExpected = 'TOPOLOGY FIX';

async function executeTopology() {
  if (tConfirm.value.trim() !== tConfirmExpected) return;
  if (Object.keys(tFixes.value).length === 0) return;
  tBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'topology_fix',
      payload: JSON.stringify({ fixes: tFixes.value }),
    })
    .toPromise();
  tBusy.value = false;
  if (res.error) { error.value = res.error.message; return; }
  lastResult.value = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction ?? null;
  tOpen.value = false;
  await refresh();
}
</script>

<template>
  <section class="webui-recovery">
    <header class="webui-recovery__head">
      <h1>Cluster recovery</h1>
      <Button
        label="Refresh"
        icon="pi pi-refresh"
        size="small"
        :loading="loading"
        @click="refresh"
      />
    </header>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <Message
      v-if="snapshot && snapshot.recommendation === 'no_action_needed'"
      severity="success"
      :closable="false"
    >
      Cluster is healthy. No recovery action required.
    </Message>

    <Message
      v-else-if="snapshot && snapshot.recommendation === 'split_brain_resolve'"
      severity="warn"
      :closable="false"
      class="webui-recovery__cta"
    >
      <strong>Split-brain detected.</strong>
      {{ splitBrainPeers.length }} peer(s) report stopped replication
      with split-brain. Run the wizard to choose a winner and recover.
      <Button
        label="Open Split-brain wizard"
        icon="pi pi-shield"
        size="small"
        severity="warn"
        @click="openSplitBrainWizard"
      />
    </Message>

    <Message
      v-else-if="snapshot && snapshot.recommendation === 'leader_takeover'"
      severity="warn"
      :closable="false"
      class="webui-recovery__cta"
    >
      <strong>No queue owner.</strong>
      No peer currently owns the synchro queue — synchronous writes
      are blocked. Pick a new leader manually.
      <Button
        label="Open Leader-takeover wizard"
        icon="pi pi-arrow-up-right"
        size="small"
        severity="warn"
        @click="openTakeoverWizard"
      />
    </Message>

    <Message
      v-else-if="snapshot && snapshot.recommendation === 'orphan_resolve'"
      severity="warn"
      :closable="false"
      class="webui-recovery__cta"
    >
      <strong>Orphan peer.</strong>
      One or more peers report status = orphan — joined but cannot
      find a writable leader. Force-reconnect or rebootstrap.
      <Button
        label="Open Orphan wizard"
        icon="pi pi-link"
        size="small"
        severity="warn"
        @click="openOrphanWizard"
      />
    </Message>

    <!-- Always-on toolbar: every wizard available regardless of
         the snapshot recommendation, so an operator can apply
         them proactively (e.g. fix a typo in cluster.yaml before
         any peer goes into the broken state). -->
    <div class="webui-recovery__toolbar">
      <Button
        label="Topology fix"
        icon="pi pi-link"
        size="small"
        severity="info"
        text
        @click="openTopologyWizard"
      />
      <Button
        label="Quorum-loss escape"
        icon="pi pi-bolt"
        size="small"
        severity="warn"
        text
        @click="openQuorumWizard"
      />
      <Button
        label="Orphan resolve"
        icon="pi pi-cog"
        size="small"
        severity="secondary"
        text
        @click="openOrphanWizard"
      />
    </div>

    <DataTable
      v-if="snapshot"
      :value="snapshot.peers"
      size="small"
      striped-rows
      :row-hover="true"
      class="webui-recovery__grid"
    >
      <Column field="alias" header="Peer" />
      <Column header="Role">
        <template #body="{ data }">
          <Tag :severity="peerRoleSeverity(data.role)" :value="data.role" />
        </template>
      </Column>
      <Column field="status" header="Status" />
      <Column header="RO">
        <template #body="{ data }">{{ data.ro === true ? 'yes' : 'no' }}</template>
      </Column>
      <Column field="last_lsn" header="Last LSN" />
      <Column field="current_term" header="Term" />
      <Column header="Reasons">
        <template #body="{ data }">
          <ul class="webui-recovery__reasons">
            <li v-for="(r, i) in data.reasons ?? []" :key="i">{{ r }}</li>
          </ul>
        </template>
      </Column>
    </DataTable>

    <section v-if="lastResult" class="webui-recovery__last">
      <h2>Last action: <code>{{ lastResult.action }}</code></h2>
      <Message
        :severity="lastResult.ok ? 'success' : 'error'"
        :closable="false"
      >
        {{ lastResult.ok ? 'completed' : (lastResult.error ?? 'failed') }}
      </Message>
      <ul>
        <li v-for="(r, i) in lastResult.results" :key="i">
          <strong>{{ r.peer }}</strong>: {{ r.ok ? 'ok' : 'FAILED' }}
          <span v-if="r.msg" class="webui-recovery__muted"> — {{ r.msg }}</span>
        </li>
      </ul>
    </section>

    <!-- Split-brain wizard -->
    <Dialog
      v-model:visible="sbOpen"
      modal
      header="Split-brain resolution"
      :style="{ width: '36rem' }"
    >
      <div class="webui-recovery__row">
        <label>Winner</label>
        <Select v-model="sbWinner" :options="peerOptions" option-label="label" option-value="value" />
      </div>
      <div class="webui-recovery__row">
        <label>Losing peers</label>
        <MultiSelect
          v-model="sbLosers"
          :options="peerOptions"
          option-label="label"
          option-value="value"
        />
      </div>
      <div class="webui-recovery__row">
        <label>Strategy</label>
        <Select
          v-model="sbAction"
          :options="[
            { label: 'Rebootstrap losing peers (clean cold-start)', value: 'rebootstrap_losing' },
            { label: 'Force-promote winner with quorum=1', value: 'force_promote_winner' },
            { label: 'Manual (do nothing automatically)', value: 'manual' },
          ]"
          option-label="label"
          option-value="value"
        />
      </div>
      <Message severity="warn" :closable="false">
        Destructive action. Type
        <code>{{ sbConfirmExpected }}</code> to confirm.
      </Message>
      <div class="webui-recovery__row">
        <label>Confirm</label>
        <input
          v-model="sbConfirm"
          class="webui-recovery__confirm"
          :placeholder="sbConfirmExpected"
        />
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="sbOpen = false" />
        <Button
          label="Resolve"
          icon="pi pi-shield"
          severity="danger"
          :loading="sbBusy"
          :disabled="sbConfirm.trim() !== sbConfirmExpected"
          @click="executeSplitBrain"
        />
      </template>
    </Dialog>

    <!-- Orphan wizard -->
    <Dialog
      v-model:visible="orOpen"
      modal
      header="Orphan resolver"
      :style="{ width: '32rem' }"
    >
      <div class="webui-recovery__row">
        <label>Orphan peer</label>
        <Select v-model="orTarget" :options="peerOptions" option-label="label" option-value="value" />
      </div>
      <div class="webui-recovery__row">
        <label>Strategy</label>
        <Select
          v-model="orAction"
          :options="[
            { label: 'Force reconnect (drop + reattach appliers)', value: 'force_reconnect' },
            { label: 'Rebootstrap (wipe + cold-boot)', value: 'rebootstrap' },
            { label: 'Solo promote (writable standalone)', value: 'solo_promote' },
          ]"
          option-label="label"
          option-value="value"
        />
      </div>
      <Message severity="warn" :closable="false">
        Type <code>{{ orConfirmExpected }}</code> to confirm.
      </Message>
      <div class="webui-recovery__row">
        <label>Confirm</label>
        <input v-model="orConfirm" class="webui-recovery__confirm" :placeholder="orConfirmExpected" />
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="orOpen = false" />
        <Button
          label="Resolve"
          icon="pi pi-link"
          severity="warn"
          :loading="orBusy"
          :disabled="orConfirm.trim() !== orConfirmExpected"
          @click="executeOrphan"
        />
      </template>
    </Dialog>

    <!-- Quorum-loss escape wizard -->
    <Dialog
      v-model:visible="qOpen"
      modal
      header="Quorum-loss escape hatch"
      :style="{ width: '36rem' }"
    >
      <Message severity="error" :closable="false">
        <strong>Dangerous.</strong>
        Flips <code>synchro_quorum</code> to 1 on the target peer
        for the chosen window. A partition during the window can
        fork the WAL — fix the underlying quorum problem ASAP
        and prefer ending the window early via cluster YAML.
      </Message>
      <div class="webui-recovery__row">
        <label>Target peer</label>
        <Select v-model="qTarget" :options="peerOptions" option-label="label" option-value="value" />
      </div>
      <div class="webui-recovery__row">
        <label>Window (seconds)</label>
        <input v-model.number="qWindow" type="number" min="5" max="3600" class="webui-recovery__confirm" />
      </div>
      <div class="webui-recovery__row">
        <label>Risk</label>
        <label class="webui-recovery__inline">
          <input v-model="qAck" type="checkbox" />
          <span>I accept the split-brain risk during the window</span>
        </label>
      </div>
      <Message severity="warn" :closable="false">
        Type <code>{{ qConfirmExpected }}</code> to confirm.
      </Message>
      <div class="webui-recovery__row">
        <label>Confirm</label>
        <input v-model="qConfirm" class="webui-recovery__confirm" :placeholder="qConfirmExpected" />
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="qOpen = false" />
        <Button
          label="Lower quorum"
          icon="pi pi-bolt"
          severity="danger"
          :loading="qBusy"
          :disabled="!qAck || qConfirm.trim() !== qConfirmExpected"
          @click="executeQuorum"
        />
      </template>
    </Dialog>

    <!-- Topology fix wizard -->
    <Dialog
      v-model:visible="tOpen"
      modal
      header="Replication topology fix"
      :style="{ width: '44rem' }"
    >
      <Message
        v-if="tPeers.length === 0"
        severity="info"
        :closable="false"
      >
        Diagnosing topology…
      </Message>
      <table v-else class="webui-recovery__topo">
        <thead>
          <tr><th>Peer</th><th>Reachable</th><th>Suggested URI</th></tr>
        </thead>
        <tbody>
          <tr v-for="p in tPeers" :key="p.alias">
            <td><code>{{ p.alias }}</code></td>
            <td>{{ p.reachable ? '✓' : '✗' }}</td>
            <td>
              <input
                v-if="tFixes[p.alias] !== undefined"
                v-model="tFixes[p.alias]"
                class="webui-recovery__confirm webui-recovery__topo-input"
              />
              <span v-else class="webui-recovery__muted">no change</span>
            </td>
          </tr>
        </tbody>
      </table>
      <Message severity="warn" :closable="false">
        Type <code>{{ tConfirmExpected }}</code> to confirm.
      </Message>
      <div class="webui-recovery__row">
        <label>Confirm</label>
        <input v-model="tConfirm" class="webui-recovery__confirm" :placeholder="tConfirmExpected" />
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="tOpen = false" />
        <Button
          label="Apply fix"
          icon="pi pi-link"
          severity="warn"
          :loading="tBusy"
          :disabled="tConfirm.trim() !== tConfirmExpected
            || Object.keys(tFixes).length === 0"
          @click="executeTopology"
        />
      </template>
    </Dialog>

    <!-- Leader takeover wizard -->
    <Dialog
      v-model:visible="ltOpen"
      modal
      header="Leader takeover"
      :style="{ width: '32rem' }"
    >
      <div class="webui-recovery__row">
        <label>New leader</label>
        <Select v-model="ltTarget" :options="peerOptions" option-label="label" option-value="value" />
      </div>
      <Message severity="warn" :closable="false">
        Drives <code>box.ctl.promote()</code> on the target peer.
        Type <code>{{ ltConfirmExpected }}</code> to confirm.
      </Message>
      <div class="webui-recovery__row">
        <label>Confirm</label>
        <input
          v-model="ltConfirm"
          class="webui-recovery__confirm"
          :placeholder="ltConfirmExpected"
        />
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="ltOpen = false" />
        <Button
          label="Promote"
          icon="pi pi-arrow-up-right"
          severity="warn"
          :loading="ltBusy"
          :disabled="ltConfirm.trim() !== ltConfirmExpected"
          @click="executeTakeover"
        />
      </template>
    </Dialog>
  </section>
</template>

<style scoped>
.webui-recovery {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-recovery__head {
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.webui-recovery__head h1 { margin: 0; }
.webui-recovery__cta :deep(.p-message-text) {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-recovery__grid { min-height: 0; }
.webui-recovery__reasons {
  list-style: none;
  margin: 0;
  padding: 0;
  font-size: 0.75rem;
  color: var(--webui-text-muted);
}
.webui-recovery__last { border-top: 1px solid var(--webui-border); padding-top: 0.5rem; }
.webui-recovery__last h2 { margin: 0 0 0.5rem 0; font-size: 1rem; }
.webui-recovery__row {
  display: grid;
  grid-template-columns: 10rem 1fr;
  gap: 0.5rem;
  align-items: center;
  margin-bottom: 0.5rem;
}
.webui-recovery__row label { color: var(--webui-text-muted); font-size: 0.85rem; }
.webui-recovery__confirm {
  background: var(--p-form-field-background, transparent);
  color: var(--p-form-field-color, inherit);
  border: 1px solid var(--p-form-field-border-color, var(--webui-border));
  border-radius: var(--webui-radius);
  padding: 0.35rem 0.5rem;
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
.webui-recovery__muted { color: var(--webui-text-muted); }
.webui-recovery__toolbar {
  display: flex;
  gap: 0.5rem;
  padding-top: 0.25rem;
  border-top: 1px dashed var(--webui-border);
}
.webui-recovery__inline {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.85rem;
}
.webui-recovery__topo {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
  margin-bottom: 0.5rem;
}
.webui-recovery__topo th,
.webui-recovery__topo td {
  text-align: left;
  padding: 0.3rem 0.5rem;
  border-bottom: 1px solid var(--webui-border);
}
.webui-recovery__topo-input { width: 100%; }
</style>
