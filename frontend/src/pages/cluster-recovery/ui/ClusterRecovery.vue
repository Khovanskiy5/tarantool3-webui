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
  split-brain; target for takeover), then hands (action, payload) to
  the shared RecoveryAssessmentPanel: a read-only `recoveryPreflight`
  computes the risk summary, and only then is `recoveryAction(...)`
  fired with the enforcement context (acknowledge / confirm token /
  fingerprint / idempotency key). safe/caution apply with one click;
  dangerous actions require the typed token in the panel.
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
import InputText from 'primevue/inputtext';
import InputNumber from 'primevue/inputnumber';
import Fluid from 'primevue/fluid';
import {
  RecoveryAssessmentPanel,
  useRecoveryAssessment,
  RECOVERY_ACTION_MUTATION,
  type ActionResult,
} from '@/features/recovery-assessment';

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

interface RecommendedAction {
  action: string;
  payload: string | null;
}

interface RecoverySnapshot {
  self_alias: string | null;
  generation: number | null;
  recommendation: string;
  recommended_action: RecommendedAction | null;
  peers: PeerEntry[];
  split_brain_groups: SplitBrainGroup[];
}

const SNAPSHOT_Q = /* GraphQL */ `
  query DrSnapshot {
    recoverySnapshot {
      self_alias
      generation
      recommendation
      recommended_action {
        action
        payload
      }
      peers {
        alias
        uuid
        replicaset
        role
        status
        ro
        reachable
        last_lsn
        current_term
        queue_owner
        reasons
      }
      split_brain_groups {
        divergent_from
        members
      }
    }
  }
`;

const loading = ref(false);
const snapshot = ref<RecoverySnapshot | null>(null);
const error = ref<string | null>(null);
const lastResult = ref<ActionResult | null>(null);

// ── Assessment-driven apply flow (RC-5) — shared composable ──────────
// Any action runs through preflight -> assessment panel -> enforced
// apply (acknowledge + typed token + decision fingerprint). The SAME
// hook drives the Suggestions banner, so the page wizards and the
// banner share one risk model (plan invariant 8).
const {
  assessOpen,
  assessBusy,
  assessment,
  assessAck,
  assessToken,
  assessError,
  openAssessment,
  applyAssessed,
} = useRecoveryAssessment({
  onApplied: async (r) => {
    lastResult.value = r;
    await refresh();
  },
});

// Apply the snapshot's recommended safe action (one click).
function applyRecommended() {
  const ra = snapshot.value?.recommended_action;
  if (ra) void openAssessment(ra.action, ra.payload);
}

async function refresh() {
  loading.value = true;
  error.value = null;
  try {
    const res = await getClient()
      .query<{
        recoverySnapshot: RecoverySnapshot;
      }>(SNAPSHOT_Q, {}, { requestPolicy: 'network-only' })
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
const sbAction = ref<'rebootstrap_losing' | 'force_promote_winner' | 'manual'>(
  'rebootstrap_losing',
);

const splitBrainPeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter((p) => p.role === 'split-brain');
});

const healthyPeers = computed(() => {
  if (snapshot.value === null) return [] as PeerEntry[];
  return snapshot.value.peers.filter((p) => p.role === 'queue-owner' || p.role === 'follower');
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
  sbWinner.value =
    healthyPeers.value.find((p) => p.queue_owner)?.alias ?? healthyPeers.value[0]?.alias ?? '';
  sbLosers.value = splitBrainPeers.value.map((p) => p.alias);
  sbAction.value = 'rebootstrap_losing';
}

// Hand off to the assessment panel (preflight -> risk summary -> apply).
function executeSplitBrain() {
  const payload = JSON.stringify({
    action: sbAction.value,
    winner_alias: sbWinner.value,
    losing_aliases: sbLosers.value,
  });
  sbOpen.value = false;
  void openAssessment('split_brain_resolve', payload);
}

// ── Leader takeover wizard ────────────────────────────────────────

const ltOpen = ref(false);
const ltTarget = ref<string>('');

function openTakeoverWizard() {
  ltOpen.value = true;
  // Pick the peer with the highest LSN as the default candidate.
  const sorted = healthyPeers.value.slice().sort((a, b) => (b.last_lsn ?? 0) - (a.last_lsn ?? 0));
  ltTarget.value = sorted[0]?.alias ?? '';
}

function executeTakeover() {
  const payload = JSON.stringify({ target_alias: ltTarget.value });
  ltOpen.value = false;
  void openAssessment('leader_takeover', payload);
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

function openOrphanWizard() {
  orOpen.value = true;
  // If a peer is actually orphan, pre-select it. Otherwise allow
  // the operator to pick any peer (the wizard is also useful as
  // a proactive force-reconnect tool, not just for true orphans)
  // — fall back to the queue owner so the destructive options
  // surface a high-impact target instead of an empty Select.
  const orphan = (snapshot.value?.peers ?? []).find((p) => p.role === 'orphan');
  const owner = (snapshot.value?.peers ?? []).find((p) => p.queue_owner);
  orTarget.value = orphan?.alias ?? owner?.alias ?? (snapshot.value?.peers ?? [])[0]?.alias ?? '';
  orAction.value = 'force_reconnect';
}

function executeOrphan() {
  const payload = JSON.stringify({
    target_alias: orTarget.value,
    action: orAction.value,
  });
  orOpen.value = false;
  void openAssessment('orphan_resolve', payload);
}

// ── Quorum loss wizard ────────────────────────────────────────────
const qOpen = ref(false);
const qTarget = ref<string>('');
const qWindow = ref<number>(300);

function openQuorumWizard() {
  qOpen.value = true;
  qTarget.value =
    (snapshot.value?.peers ?? []).find((p) => p.queue_owner)?.alias ??
    (snapshot.value?.peers ?? [])[0]?.alias ??
    '';
  qWindow.value = 300;
}

function executeQuorum() {
  const payload = JSON.stringify({
    target_alias: qTarget.value,
    window_sec: qWindow.value,
    risk_acknowledged: true,
  });
  qOpen.value = false;
  void openAssessment('quorum_loss_escape', payload);
}

// ── Topology fix wizard ───────────────────────────────────────────
interface TopologyPeer {
  alias: string;
  declared_uri: string | null;
  observed_uri: string | null;
  reachable: boolean;
  suggestion: string | null;
  needsFix: boolean;
}
const tOpen = ref(false);
const tPeers = ref<TopologyPeer[]>([]);
const tFixes = ref<Record<string, string>>({});
const tDiagnosed = ref(false);

async function openTopologyWizard() {
  tOpen.value = true;
  tDiagnosed.value = false;
  tPeers.value = [];
  tFixes.value = {};
  // Use the diagnose pseudo-action — backend returns its
  // diagnostic via the standard recoveryAction shape so the
  // results array carries one row per peer with `msg` filled
  // when a fix is suggested.
  const diag = await getClient()
    .mutation(RECOVERY_ACTION_MUTATION, {
      action: 'topology_fix_diagnose',
      payload: null,
    })
    .toPromise();
  const arr: TopologyPeer[] = [];
  const peers =
    (diag.data as { recoveryAction: ActionResult } | undefined)?.recoveryAction?.results ?? [];
  for (const p of peers) {
    // `msg` is a JSON envelope: { declared, observed, reachable, suggestion }.
    let detail: {
      declared?: string | null;
      observed?: string | null;
      reachable?: boolean;
      suggestion?: string | null;
    } = {};
    if (p.msg) {
      try {
        detail = JSON.parse(p.msg);
      } catch {
        detail = {};
      }
    }
    arr.push({
      alias: p.peer,
      declared_uri: detail.declared ?? null,
      observed_uri: detail.observed ?? null,
      reachable: detail.reachable === true,
      suggestion: detail.suggestion ?? null,
      // `ok` from the backend means "no action needed".
      needsFix: !p.ok,
    });
  }
  tPeers.value = arr;
  for (const p of arr) {
    if (p.needsFix) {
      // Pre-fill the editable field: the auto-detected URI when we have
      // one, otherwise the declared URI so the operator just corrects
      // the typo.
      tFixes.value[p.alias] = p.suggestion ?? p.declared_uri ?? '';
    }
  }
  tDiagnosed.value = true;
}

function executeTopology() {
  if (Object.keys(tFixes.value).length === 0) return;
  const payload = JSON.stringify({ fixes: tFixes.value });
  tOpen.value = false;
  void openAssessment('topology_fix', payload);
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
    .mutation(RECOVERY_ACTION_MUTATION, {
      action: 'wal_diagnose',
      payload: null,
    })
    .toPromise();
  wBusy.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  const r = (res.data as { recoveryAction: ActionResult } | undefined)?.recoveryAction;
  if (r === undefined || !r.ok) return;
  wFiles.value = r.results.map((x) => ({
    file: x.peer,
    ok: x.ok,
    msg: x.msg ?? '',
  }));
}

function quarantineWal(row: WalRow) {
  if (row.ok) return;
  // Route through the assessment panel: it classifies tail vs mid-chain
  // corruption and gates a dangerous (mid-chain) quarantine behind a token.
  const payload = JSON.stringify({ file: row.file });
  wOpen.value = false;
  void openAssessment('wal_quarantine', payload);
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
      {{ splitBrainPeers.length }} peer(s) report stopped replication with split-brain. Run the
      wizard to choose a winner and recover.
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
      No peer currently owns the synchro queue — synchronous writes are blocked. Pick a new leader
      manually.
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
      One or more peers report status = orphan — joined but cannot find a writable leader.
      Force-reconnect or rebootstrap.
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
      {{ unreachablePeers.length }} peer(s) unreachable — quorum is still intact, but the cluster
      can no longer tolerate another failure. Investigate the missing peer(s) before they cause an
      outage.
    </Message>

    <!-- One-click apply of the snapshot's recommended SAFE action.
         Shown only when the backend computed a safe auto-target; goes
         through preflight + the assessment panel like any action. -->
    <Message v-if="snapshot && snapshot.recommended_action" severity="info" :closable="false">
      A recommended recovery action is available.
      <Button
        label="Apply recommended"
        icon="pi pi-bolt"
        size="small"
        class="ml-2"
        @click="applyRecommended"
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
      <Button
        label="Leader takeover"
        icon="pi pi-arrow-up-right"
        size="small"
        severity="warn"
        text
        @click="openTakeoverWizard"
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
      <h2>
        Last action: <code>{{ lastResult.action }}</code>
      </h2>
      <Message :severity="lastResult.ok ? 'success' : 'error'" :closable="false">
        {{ lastResult.ok ? 'completed' : (lastResult.error ?? 'failed') }}
      </Message>
      <ul>
        <li v-for="(r, i) in lastResult.results" :key="i">
          <strong>{{ r.peer }}</strong
          >: {{ r.ok ? 'ok' : 'FAILED' }}
          <span v-if="r.msg" class="webui-recovery__muted"> — {{ r.msg }}</span>
        </li>
      </ul>
    </section>

    <!-- Risk-assessment dialog (preflight -> panel -> apply). -->
    <Dialog
      v-model:visible="assessOpen"
      modal
      header="Recovery — risk assessment"
      :style="{ width: '34rem' }"
    >
      <Message v-if="assessError" severity="error" :closable="false" class="mb-2">
        {{ assessError }}
      </Message>
      <div v-if="assessBusy && !assessment" class="webui-recovery__muted">Assessing…</div>
      <RecoveryAssessmentPanel
        v-else
        v-model:acknowledge="assessAck"
        v-model:token="assessToken"
        :assessment="assessment"
        :busy="assessBusy"
        @apply="applyAssessed"
        @cancel="assessOpen = false"
      />
    </Dialog>

    <!-- Split-brain wizard -->
    <Dialog
      v-model:visible="sbOpen"
      modal
      header="Split-brain resolution"
      :style="{ width: '32rem' }"
    >
      <div class="r-body">
        <Fluid>
          <div class="r-field">
            <label for="sb-winner">Winner</label>
            <Select
              v-model="sbWinner"
              input-id="sb-winner"
              :options="peerOptions"
              option-label="label"
              option-value="value"
            />
          </div>
          <div class="r-field">
            <label for="sb-losers">Losing peers</label>
            <MultiSelect
              v-model="sbLosers"
              input-id="sb-losers"
              :options="peerOptions"
              option-label="label"
              option-value="value"
            />
          </div>
          <div class="r-field">
            <label for="sb-strategy">Strategy</label>
            <Select
              v-model="sbAction"
              input-id="sb-strategy"
              :options="[
                {
                  label: 'Rebootstrap losing peers (clean cold-start)',
                  value: 'rebootstrap_losing',
                },
                { label: 'Force-promote winner with quorum=1', value: 'force_promote_winner' },
                { label: 'Manual (do nothing automatically)', value: 'manual' },
              ]"
              option-label="label"
              option-value="value"
            />
          </div>
        </Fluid>
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="sbOpen = false" />
        <Button
          label="Review…"
          icon="pi pi-shield"
          :disabled="!sbWinner"
          @click="executeSplitBrain"
        />
      </template>
    </Dialog>

    <!-- Orphan wizard -->
    <Dialog v-model:visible="orOpen" modal header="Orphan resolver" :style="{ width: '32rem' }">
      <div class="r-body">
        <Message v-if="orphanPeers.length === 0" severity="info" :closable="false">
          No peers currently report status = orphan. The wizard is still usable as a proactive
          force-reconnect / rebootstrap for any peer — pick the target manually.
        </Message>
        <Message v-else severity="warn" :closable="false">
          Detected orphan peer(s): <strong>{{ orphanPeers.map((p) => p.alias).join(', ') }}</strong
          >.
        </Message>
        <Fluid>
          <div class="r-field">
            <label for="or-target">Target peer</label>
            <Select
              v-model="orTarget"
              input-id="or-target"
              :options="peerOptions"
              option-label="label"
              option-value="value"
            />
          </div>
          <div class="r-field">
            <label for="or-strategy">Strategy</label>
            <Select
              v-model="orAction"
              input-id="or-strategy"
              :options="[
                { label: 'Force reconnect (drop + reattach appliers)', value: 'force_reconnect' },
                { label: 'Rebootstrap (wipe + cold-boot)', value: 'rebootstrap' },
                { label: 'Solo promote (writable standalone)', value: 'solo_promote' },
              ]"
              option-label="label"
              option-value="value"
            />
          </div>
        </Fluid>
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="orOpen = false" />
        <Button label="Review…" icon="pi pi-link" :disabled="!orTarget" @click="executeOrphan" />
      </template>
    </Dialog>

    <!-- Quorum-loss escape wizard -->
    <Dialog
      v-model:visible="qOpen"
      modal
      header="Quorum-loss escape hatch"
      :style="{ width: '34rem' }"
    >
      <div class="r-body">
        <Message severity="error" :closable="false">
          <strong>Dangerous.</strong>
          Flips <code>synchro_quorum</code> to 1 on the target peer for the chosen window. A
          partition during the window can fork the WAL — fix the underlying quorum problem ASAP and
          prefer ending the window early via cluster YAML.
        </Message>
        <Message v-if="unreachablePeers.length === 0" severity="info" :closable="false">
          Every peer is currently reachable. The escape hatch is usually applied when one or more
          peers are unreachable and synchronous writes start blocking. Opening it proactively is
          fine but you almost certainly want to wait.
        </Message>
        <Fluid>
          <div class="r-field">
            <label for="q-target">Target peer</label>
            <Select
              v-model="qTarget"
              input-id="q-target"
              :options="peerOptions"
              option-label="label"
              option-value="value"
            />
            <Message
              v-if="qTarget && qTarget === currentQueueOwner"
              size="small"
              severity="secondary"
              variant="simple"
            >
              Selected peer is the current queue owner.
            </Message>
          </div>
          <div class="r-field">
            <label for="q-window">Window (seconds)</label>
            <InputNumber
              v-model="qWindow"
              input-id="q-window"
              :min="5"
              :max="3600"
              :use-grouping="false"
            />
            <Message size="small" severity="secondary" variant="simple">
              Auto-restores original quorum after this window.
            </Message>
          </div>
        </Fluid>
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="qOpen = false" />
        <Button label="Review…" icon="pi pi-bolt" :disabled="!qTarget" @click="executeQuorum" />
      </template>
    </Dialog>

    <!-- Topology fix wizard -->
    <Dialog
      v-model:visible="tOpen"
      modal
      header="Replication topology fix"
      :style="{ width: '40rem' }"
    >
      <div class="r-body">
        <Message v-if="!tDiagnosed" severity="info" :closable="false">
          Diagnosing topology…
        </Message>
        <Message v-else-if="Object.keys(tFixes).length === 0" severity="success" :closable="false">
          No replication topology issues detected. Every declared peer is reachable and its URI
          matches what the cluster observes. Nothing to fix.
        </Message>
        <DataTable v-else :value="tPeers" size="small" striped-rows data-key="alias">
          <Column header="Peer">
            <template #body="{ data }">
              <code>{{ data.alias }}</code>
            </template>
          </Column>
          <Column header="Reachable">
            <template #body="{ data }">
              <Tag
                :severity="data.reachable ? 'success' : 'danger'"
                :value="data.reachable ? 'yes' : 'no'"
              />
            </template>
          </Column>
          <Column header="Declared URI">
            <template #body="{ data }">
              <code>{{ data.declared_uri ?? '—' }}</code>
            </template>
          </Column>
          <Column header="URI to apply">
            <template #body="{ data }">
              <Fluid v-if="tFixes[data.alias] !== undefined">
                <InputText v-model="tFixes[data.alias]" />
              </Fluid>
              <Message v-else size="small" severity="secondary" variant="simple">
                no change
              </Message>
            </template>
          </Column>
        </DataTable>
        <Message
          v-if="tDiagnosed && tPeers.some((p) => !p.reachable)"
          severity="warn"
          size="small"
          variant="simple"
          :closable="false"
        >
          An unreachable peer either has a wrong URI — correct it above and apply — or the instance
          is simply stopped, in which case the declared URI is fine and you should start the process
          instead.
        </Message>
      </div>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="tOpen = false" />
        <Button
          v-if="tDiagnosed && Object.keys(tFixes).length > 0"
          label="Review…"
          icon="pi pi-link"
          @click="executeTopology"
        />
      </template>
    </Dialog>

    <!-- WAL repair wizard -->
    <Dialog v-model:visible="wOpen" modal header="WAL chain repair" :style="{ width: '46rem' }">
      <div class="r-body">
        <Message severity="warn" :closable="false">
          Lists every .xlog on this instance with an integrity probe. Files marked
          <strong>BAD</strong> can be quarantined (renamed to <code>.corrupt</code>) so the next
          boot skips them. After quarantine, restart the instance with
          <code>force_recovery = true</code> in cluster YAML to let the bootstrap continue past the
          gap.
        </Message>
        <Message v-if="wBusy" severity="info" :closable="false">Probing WAL files…</Message>
        <Message v-else-if="wFiles.length === 0" severity="info" :closable="false">
          No .xlog files reported for this instance.
        </Message>
        <DataTable v-else :value="wFiles" size="small" striped-rows data-key="file">
          <Column header="File">
            <template #body="{ data }">
              <code>{{ data.file }}</code>
            </template>
          </Column>
          <Column header="Status">
            <template #body="{ data }">
              <Tag :severity="data.ok ? 'success' : 'danger'" :value="data.ok ? 'OK' : 'BAD'" />
            </template>
          </Column>
          <Column field="msg" header="Detail" />
          <Column header="">
            <template #body="{ data }">
              <Button
                v-if="!data.ok"
                icon="pi pi-trash"
                size="small"
                severity="danger"
                text
                aria-label="Quarantine"
                @click="quarantineWal(data)"
              />
            </template>
          </Column>
        </DataTable>
      </div>
      <template #footer>
        <Button label="Close" severity="secondary" text @click="wOpen = false" />
      </template>
    </Dialog>

    <!-- Leader takeover wizard -->
    <Dialog v-model:visible="ltOpen" modal header="Leader takeover" :style="{ width: '32rem' }">
      <div class="r-body">
        <Message v-if="currentQueueOwner" severity="info" :closable="false">
          Current queue owner: <strong>{{ currentQueueOwner }}</strong
          >. Default candidate has the highest LSN among healthy peers.
        </Message>
        <Message v-else severity="error" :closable="false">
          <strong>No queue owner detected.</strong>
          Cluster cannot accept synchronous writes — pick a leader and promote it.
        </Message>
        <Fluid>
          <div class="r-field">
            <label for="lt-target">New leader</label>
            <Select
              v-model="ltTarget"
              input-id="lt-target"
              :options="peerOptions"
              option-label="label"
              option-value="value"
            />
            <Message
              v-if="ltTarget && ltTarget === currentQueueOwner"
              size="small"
              severity="warn"
              variant="simple"
            >
              Selected peer already owns the queue — pick a different one.
            </Message>
          </div>
        </Fluid>
      </div>
      <template #footer>
        <Button label="Cancel" severity="secondary" text @click="ltOpen = false" />
        <Button
          label="Review…"
          icon="pi pi-arrow-up-right"
          :disabled="!ltTarget"
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
.webui-recovery__head h1 {
  margin: 0;
}
.webui-recovery__cta :deep(.p-message-text) {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-recovery__grid {
  min-height: 0;
}
.webui-recovery__reasons {
  list-style: none;
  margin: 0;
  padding: 0;
  font-size: 0.75rem;
  color: var(--webui-text-muted);
}
.webui-recovery__last {
  border-top: 1px solid var(--webui-border);
  padding-top: 0.5rem;
}
.webui-recovery__last h2 {
  margin: 0 0 0.5rem 0;
  font-size: 1rem;
}
.webui-recovery__muted {
  color: var(--webui-text-muted);
}
.webui-recovery__toolbar {
  display: flex;
  gap: 0.5rem;
  padding-top: 0.25rem;
  border-top: 1px dashed var(--webui-border);
}

/* ── Recovery Wizard Forms ──────────────────────────────────────
   Follow the PrimeVue Aura Dialog idiom verbatim:
   - Dialog content already has 1.25rem padding from the theme
     (overlay.modal.padding) — do NOT add a border between
     content and footer, and do NOT override paddings.
   - Form fields use the official "label-stacked" pattern from
     PrimeVue's InputText/HelpText docs:
         <div class="r-field">
           <label>…</label>
           <Component … />
           <Message size="small" severity="secondary" variant="simple">help…</Message>
         </div>
   - Multiple fields stack inside a `<Fluid>` so every control
     auto-fills the column. The Fluid gap is set in CSS below.
*/

.r-body {
  display: flex;
  flex-direction: column;
  gap: 1.25rem;
}
.r-body :deep(.p-fluid) {
  display: flex;
  flex-direction: column;
  gap: 1.25rem;
}

.r-field {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  min-width: 0;
}
.r-field label {
  font-size: 0.875rem;
  font-weight: 600;
}
</style>
