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

const unreachablePeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter((p) => p.role === 'unreachable');
});

const orphanPeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter((p) => p.role === 'orphan');
});

const currentQueueOwner = computed(() => {
  if (snapshot.value === null) return null;
  return snapshot.value.peers.find((p) => p.queue_owner)?.alias ?? null;
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
  // If a peer is actually orphan, pre-select it. Otherwise allow
  // the operator to pick any peer (the wizard is also useful as
  // a proactive force-reconnect tool, not just for true orphans)
  // — fall back to the queue owner so the destructive options
  // surface a high-impact target instead of an empty Select.
  const orphan = (snapshot.value?.peers ?? []).find((p) => p.role === 'orphan');
  const owner = (snapshot.value?.peers ?? []).find((p) => p.queue_owner);
  orTarget.value = orphan?.alias
    ?? owner?.alias
    ?? (snapshot.value?.peers ?? [])[0]?.alias
    ?? '';
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
const tDiagnosed = ref(false);

async function openTopologyWizard() {
  tOpen.value = true;
  tConfirm.value = '';
  tBusy.value = false;
  tDiagnosed.value = false;
  tPeers.value = [];
  tFixes.value = {};
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
  for (const p of arr) {
    if (p.suggestion) {
      // suggestion msg currently encodes `declared=X observed=Y`
      // — pull the Y portion as the proposed value.
      const m = p.suggestion.match(/observed=(\S+)/);
      if (m) tFixes.value[p.alias] = m[1];
    }
  }
  tDiagnosed.value = true;
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

// ── PITR (point-in-time recovery) wizard — advisory ───────────────
const pOpen = ref(false);
const pTargetLsn = ref<number>(0);
const pCurrentLsn = ref<number>(0);
const pCommands = ref<string[]>([]);
const pCopied = ref(false);
const pBusy = ref(false);

async function openPitrWizard() {
  pOpen.value = true;
  pCommands.value = [];
  pBusy.value = false;
  // Default target = current LSN minus a sane delta. For a small
  // dev cluster (current_lsn=97) `-100` would clamp to 0 and the
  // backend rejects negatives — pick half-step instead so the
  // default is always a runnable starting point. The operator
  // edits it to whatever incident point matters.
  const owner = (snapshot.value?.peers ?? []).find((p) => p.queue_owner);
  const cur = owner?.last_lsn ?? 0;
  pCurrentLsn.value = cur;
  pTargetLsn.value = cur > 200 ? cur - 100 : Math.max(1, Math.floor(cur / 2));
}

async function copyPitrCommands() {
  if (pCommands.value.length === 0) return;
  try {
    await navigator.clipboard.writeText(pCommands.value.join('\n'));
    pCopied.value = true;
    setTimeout(() => { pCopied.value = false; }, 1500);
  } catch {
    pCopied.value = false;
  }
}

async function generatePitrPlan() {
  if (!pTargetLsn.value || pTargetLsn.value < 0) return;
  pBusy.value = true;
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'pitr_plan',
      payload: JSON.stringify({ target_lsn: pTargetLsn.value }),
    })
    .toPromise();
  pBusy.value = false;
  if (res.error) {
    error.value = res.error.message;
    pCommands.value = [];
    return;
  }
  const r = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction;
  if (r === undefined || !r.ok) {
    error.value = r?.error ?? 'pitr plan failed';
    pCommands.value = [];
    return;
  }
  // Each result row carries one command line in `msg`.
  pCommands.value = r.results.map((x) => x.msg ?? '');
}

// ── WAL repair wizard ─────────────────────────────────────────────
interface WalRow {
  file: string;
  ok: boolean;
  msg: string;
}
const wOpen = ref(false);
const wFiles = ref<WalRow[]>([]);
const wBusy = ref(false);

async function openWalRepairWizard() {
  wOpen.value = true;
  wBusy.value = true;
  wFiles.value = [];
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'wal_diagnose',
      payload: null,
    })
    .toPromise();
  wBusy.value = false;
  if (res.error) { error.value = res.error.message; return; }
  const r = (res.data as { recoveryAction: ActionResult } | undefined)
    ?.recoveryAction;
  if (r === undefined || !r.ok) return;
  wFiles.value = r.results.map((x) => ({
    file: x.peer, ok: x.ok, msg: x.msg ?? '',
  }));
}

async function quarantineWal(row: WalRow) {
  if (row.ok) return;
  if (!window.confirm(`Quarantine ${row.file}? `
    + `It will be renamed to ${row.file}.corrupt and skipped on next boot.`)) {
    return;
  }
  const res = await getClient()
    .mutation(ACTION_M, {
      action: 'wal_quarantine',
      payload: JSON.stringify({ file: row.file }),
    })
    .toPromise();
  if (res.error) { error.value = res.error.message; return; }
  // Refresh the diagnostic so the quarantined file disappears.
  await openWalRepairWizard();
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

    <Message
      v-else-if="snapshot && snapshot.recommendation === 'degraded'"
      severity="warn"
      :closable="false"
    >
      <strong>Cluster degraded.</strong>
      {{ unreachablePeers.length }} peer(s) unreachable — quorum is
      still intact, but the cluster can no longer tolerate another
      failure. Investigate the missing peer(s) before they cause an
      outage.
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
      <Button
        label="Leader takeover"
        icon="pi pi-arrow-up-right"
        size="small"
        severity="warn"
        text
        @click="openTakeoverWizard"
      />
      <Button
        label="PITR plan"
        icon="pi pi-history"
        size="small"
        severity="info"
        text
        @click="openPitrWizard"
      />
      <Button
        label="WAL repair"
        icon="pi pi-wrench"
        size="small"
        severity="warn"
        text
        @click="openWalRepairWizard"
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
        <template #body="{ data }">
          <span v-if="!data.reachable" class="webui-recovery__muted">—</span>
          <template v-else>{{ data.ro === true ? 'yes' : 'no' }}</template>
        </template>
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
      <Message
        v-if="orphanPeers.length === 0"
        severity="info"
        :closable="false"
      >
        No peers currently report status = orphan. The wizard is
        still usable as a proactive force-reconnect / rebootstrap
        for any peer — pick the target manually.
      </Message>
      <Message
        v-else
        severity="warn"
        :closable="false"
      >
        Detected orphan peer(s): <strong>{{ orphanPeers.map((p) => p.alias).join(', ') }}</strong>.
      </Message>
      <div class="webui-recovery__row">
        <label>Target peer</label>
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
      <Message
        v-if="unreachablePeers.length === 0"
        severity="info"
        :closable="false"
      >
        Every peer is currently reachable. The escape hatch is
        usually applied when one or more peers are unreachable and
        synchronous writes start blocking. Opening it proactively
        is fine but you almost certainly want to wait.
      </Message>
      <div class="webui-recovery__row">
        <label>Target peer</label>
        <Select v-model="qTarget" :options="peerOptions" option-label="label" option-value="value" />
        <span v-if="qTarget && qTarget === currentQueueOwner" class="webui-recovery__muted">
          ← current queue owner
        </span>
      </div>
      <div class="webui-recovery__row">
        <label>Window (seconds)</label>
        <input v-model.number="qWindow" type="number" min="5" max="3600" class="webui-recovery__confirm" />
        <span class="webui-recovery__muted">
          auto-restores original quorum after this window
        </span>
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
        v-if="!tDiagnosed"
        severity="info"
        :closable="false"
      >
        Diagnosing topology…
      </Message>
      <Message
        v-else-if="Object.keys(tFixes).length === 0"
        severity="success"
        :closable="false"
      >
        No replication topology issues detected. Every declared peer
        URI matches what the cluster observes. Nothing to fix.
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
      <template v-if="tDiagnosed && Object.keys(tFixes).length > 0">
        <Message severity="warn" :closable="false">
          Type <code>{{ tConfirmExpected }}</code> to confirm.
        </Message>
        <div class="webui-recovery__row">
          <label>Confirm</label>
          <input v-model="tConfirm" class="webui-recovery__confirm" :placeholder="tConfirmExpected" />
        </div>
      </template>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="tOpen = false" />
        <Button
          v-if="tDiagnosed && Object.keys(tFixes).length > 0"
          label="Apply fix"
          icon="pi pi-link"
          severity="warn"
          :loading="tBusy"
          :disabled="tConfirm.trim() !== tConfirmExpected"
          @click="executeTopology"
        />
      </template>
    </Dialog>

    <!-- PITR wizard -->
    <Dialog
      v-model:visible="pOpen"
      modal
      header="Point-in-time recovery (advisory)"
      :style="{ width: '50rem' }"
    >
      <Message severity="info" :closable="false">
        Tarantool 3.x PITR requires an offline restart, which the
        WebUI cannot drive for itself. This wizard generates the
        exact host-side commands you run; the recovery happens
        outside this page.
      </Message>
      <div class="webui-recovery__row">
        <label>Target LSN</label>
        <input
          v-model.number="pTargetLsn"
          type="number"
          min="1"
          :max="pCurrentLsn || undefined"
          class="webui-recovery__confirm"
        />
        <span v-if="pCurrentLsn > 0" class="webui-recovery__muted">
          current = {{ pCurrentLsn }}
        </span>
      </div>
      <Button
        label="Generate plan"
        icon="pi pi-history"
        size="small"
        severity="info"
        :loading="pBusy"
        :disabled="!pTargetLsn || pTargetLsn < 1"
        @click="generatePitrPlan"
      />
      <div v-if="pCommands.length > 0" class="webui-recovery__commands-wrap">
        <div class="webui-recovery__commands-head">
          <span class="webui-recovery__muted">
            Run these commands on the host (one block per peer):
          </span>
          <Button
            :label="pCopied ? 'Copied!' : 'Copy'"
            :icon="pCopied ? 'pi pi-check' : 'pi pi-copy'"
            size="small"
            text
            severity="secondary"
            @click="copyPitrCommands"
          />
        </div>
        <pre class="webui-recovery__commands">{{ pCommands.join('\n') }}</pre>
      </div>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="pOpen = false" />
      </template>
    </Dialog>

    <!-- WAL repair wizard -->
    <Dialog
      v-model:visible="wOpen"
      modal
      header="WAL chain repair"
      :style="{ width: '48rem' }"
    >
      <Message severity="warn" :closable="false">
        Lists every .xlog on this instance with an integrity probe.
        Files marked <strong>BAD</strong> can be quarantined
        (renamed to <code>.corrupt</code>) so the next boot skips
        them. After quarantine, restart the instance with
        <code>force_recovery = true</code> in cluster YAML to
        let the bootstrap continue past the gap.
      </Message>
      <table class="webui-recovery__topo">
        <thead>
          <tr><th>File</th><th>Status</th><th>Detail</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="row in wFiles" :key="row.file">
            <td><code>{{ row.file }}</code></td>
            <td>
              <Tag
                :severity="row.ok ? 'success' : 'danger'"
                :value="row.ok ? 'OK' : 'BAD'"
              />
            </td>
            <td class="webui-recovery__muted">{{ row.msg }}</td>
            <td>
              <Button
                v-if="!row.ok"
                icon="pi pi-trash"
                size="small"
                severity="danger"
                text
                @click="quarantineWal(row)"
              />
            </td>
          </tr>
        </tbody>
      </table>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="wOpen = false" />
      </template>
    </Dialog>

    <!-- Leader takeover wizard -->
    <Dialog
      v-model:visible="ltOpen"
      modal
      header="Leader takeover"
      :style="{ width: '32rem' }"
    >
      <Message
        v-if="currentQueueOwner"
        severity="info"
        :closable="false"
      >
        Current queue owner: <strong>{{ currentQueueOwner }}</strong>.
        Default candidate has the highest LSN among healthy peers.
      </Message>
      <Message
        v-else
        severity="error"
        :closable="false"
      >
        <strong>No queue owner detected.</strong>
        Cluster cannot accept synchronous writes — pick a leader and
        promote it.
      </Message>
      <div class="webui-recovery__row">
        <label>New leader</label>
        <Select v-model="ltTarget" :options="peerOptions" option-label="label" option-value="value" />
      </div>
      <Message
        v-if="ltTarget && ltTarget === currentQueueOwner"
        severity="warn"
        :closable="false"
      >
        Selected peer already owns the queue. Promote on a different
        peer to actually take leadership over.
      </Message>
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
  grid-template-columns: 10rem 1fr auto;
  gap: 0.5rem;
  align-items: center;
}

/* Recovery dialogs were a soup of stacked Message banners, rows
   and tables with ad-hoc margins. Stack every top-level child of
   the dialog body with a uniform gap so banners breathe, rows
   line up, and the destructive footer reads as a separate region.
   Targeting `.p-dialog-content` via :deep — that is the PrimeVue
   container that wraps the dialog body. */
:deep(.p-dialog-content) {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
/* Visual divider between the body and the action buttons so the
   destructive footer stops looking glued to the form fields. */
:deep(.p-dialog-footer) {
  border-top: 1px solid var(--webui-border);
  padding-top: 0.75rem;
  margin-top: 0.25rem;
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
}
.webui-recovery__topo th,
.webui-recovery__topo td {
  text-align: left;
  padding: 0.3rem 0.5rem;
  border-bottom: 1px solid var(--webui-border);
}
.webui-recovery__topo-input { width: 100%; }
.webui-recovery__commands {
  background: var(--p-content-background, #0e1117);
  color: var(--p-text-color, inherit);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  padding: 0.75rem;
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
  white-space: pre-wrap;
  max-height: 24rem;
  overflow: auto;
  margin: 0;
}
.webui-recovery__commands-wrap {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}
.webui-recovery__commands-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.5rem;
}
</style>
