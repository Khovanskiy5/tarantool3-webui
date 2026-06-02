<script setup lang="ts">
import { computed, onMounted, onScopeDispose, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';

import { getClient } from '@/shared/api/graphql';
import { wsClient } from '@/shared/api/ws';
import { useSessionStore } from '@/entities/session';
import { FailoverSettingsDialog } from '@/features/cluster-ops';

interface Election {
  instance: string;
  state: string | null;
  term: number | null;
  leader_name: string | null;
}

interface SPEndpoint {
  uri: string;
  status: string;
  latency_ms: number | null;
  last_error: string | null;
}

interface SPStatus {
  kind: 'etcd' | 'none' | string;
  mode: string;
  endpoints: SPEndpoint[] | null;
  lease_active: boolean | null;
  coordinator: string | null;
}

interface Appointment {
  replicaset: string;
  leader: string | null;
  previous: string | null;
  ts: number | null;
}

interface AgentStatus {
  enabled: boolean;
  self_alias: string | null;
  coordinator: string | null;
  is_coordinator: boolean | null;
  lease_id: string | null;
  appointments: Appointment[];
  last_error: string | null;
  watcher_replicaset: string | null;
  watcher_last_leader: string | null;
  watcher_current_ro: boolean | null;
}

interface FailoverCommand {
  id: number;
  ts: number;
  command_type: string;
  params: string | null;
  status: string;
  user: string | null;
  coordinator: string | null;
  taken_at: number | null;
  completed_at: number | null;
  error_reason: string | null;
}

interface LivenessEntry {
  alias: string | null;
  hostname: string | null;
  pid: number | null;
  mode: string | null;
  ro_reason: string | null;
  status: string | null;
  ts: number | null;
  age_seconds: number | null;
}

interface LivenessReport {
  reporter_enabled: boolean;
  keepalive_interval: number | null;
  entries: LivenessEntry[];
}

const mode = ref<string>('');
const elections = ref<Election[]>([]);
const sp = ref<SPStatus | null>(null);
const agent = ref<AgentStatus | null>(null);
const commands = ref<FailoverCommand[]>([]);
const liveness = ref<LivenessReport | null>(null);
const error = ref<string | null>(null);
const loading = ref(false);
const settingsOpen = ref(false);
const instanceCount = ref<number>(0);

const session = useSessionStore();
const canEditFailover = computed(() => session.hasRole('admin'));

const FAILOVER_Q = /* GraphQL */ `
  query Failover {
    failover {
      mode
      elections {
        instance
        state
        term
        leader_name
      }
    }
    failoverStateProviderStatus {
      kind
      mode
      lease_active
      coordinator
      endpoints {
        uri
        status
        latency_ms
        last_error
      }
    }
    failoverAgentStatus {
      enabled
      self_alias
      coordinator
      is_coordinator
      lease_id
      last_error
      watcher_replicaset
      watcher_last_leader
      watcher_current_ro
      appointments {
        replicaset
        leader
        previous
        ts
      }
    }
    failoverCommands(limit: 50) {
      entries {
        id
        ts
        command_type
        params
        status
        user
        coordinator
        taken_at
        completed_at
        error_reason
      }
    }
    clusterLiveness {
      reporter_enabled
      keepalive_interval
      entries {
        alias
        hostname
        pid
        mode
        ro_reason
        status
        ts
        age_seconds
      }
    }
    cluster {
      servers(limit: 50) {
        totalCount
      }
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient()
    .query<{
      failover: { mode: string; elections: Election[] };
      failoverStateProviderStatus: SPStatus;
      failoverAgentStatus: AgentStatus;
      failoverCommands: { entries: FailoverCommand[] };
      clusterLiveness: LivenessReport;
      cluster: { servers: { totalCount: number } };
    }>(FAILOVER_Q, {}, { requestPolicy: 'network-only' })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loading.value = false;
    return;
  }
  mode.value = res.data?.failover?.mode ?? 'unknown';
  elections.value = res.data?.failover?.elections ?? [];
  sp.value = res.data?.failoverStateProviderStatus ?? null;
  agent.value = res.data?.failoverAgentStatus ?? null;
  commands.value = res.data?.failoverCommands?.entries ?? [];
  liveness.value = res.data?.clusterLiveness ?? null;
  instanceCount.value = res.data?.cluster?.servers?.totalCount ?? 0;
  loading.value = false;
};

const fmtAge = (ts: number | null): string => {
  if (ts == null) return '—';
  const dt = new Date(ts * 1000);
  return dt.toISOString().replace('T', ' ').slice(0, 19) + 'Z';
};

const sev = (state: string | null) =>
  state === 'leader' ? 'success' : state === 'follower' ? 'info' : 'warn';
const epSev = (status: string) => (status === 'ok' ? 'success' : 'danger');
const cmdSev = (status: string) => {
  if (status === 'success') return 'success';
  if (status === 'failed') return 'danger';
  if (status === 'taken') return 'info';
  return 'secondary';
};

// Liveness freshness vs. the keepalive interval reported by the
// backend. Anything older than 2x is treated as stale — that gives
// one missed renew_interval window before raising the alarm.
const liveSev = (entry: LivenessEntry): 'success' | 'warn' | 'danger' => {
  if (entry.age_seconds == null) return 'warn';
  const threshold = liveness.value?.keepalive_interval ?? 10;
  if (entry.age_seconds > threshold * 2) return 'danger';
  if (entry.age_seconds > threshold) return 'warn';
  return 'success';
};
const liveLabel = (entry: LivenessEntry): string => {
  if (entry.age_seconds == null) return 'unknown';
  const threshold = liveness.value?.keepalive_interval ?? 10;
  if (entry.age_seconds > threshold * 2) return 'stale';
  if (entry.age_seconds > threshold) return 'lagging';
  return 'fresh';
};
const fmtAgeShort = (sec: number | null): string => {
  if (sec == null) return '—';
  if (sec < 1) return '<1 s';
  if (sec < 60) return `${sec.toFixed(1)} s`;
  return `${(sec / 60).toFixed(1)} min`;
};

// Pretty-print latency only when start + finish are known. Pending /
// taken rows leave the cell empty so it does not show "NaN ms".
const cmdLatency = (cmd: FailoverCommand): string => {
  if (cmd.completed_at == null) return '—';
  const start = cmd.taken_at ?? cmd.ts;
  if (start == null) return '—';
  const dt = (cmd.completed_at - start) * 1000;
  if (dt < 1) return '<1 ms';
  if (dt < 1000) return `${dt.toFixed(0)} ms`;
  return `${(dt / 1000).toFixed(2)} s`;
};

// Refresh commands on every WS snapshot tick. Phase 5.13 plans a
// dedicated `failover.command_updated` event for sub-second
// freshness; until then the existing snapshot cadence (about 1-2 s)
// is enough for the operator workflow.
const unsubMsg = wsClient.onMessage((msg) => {
  if (msg.type === 'snapshot' || msg.type === 'initial') {
    void load();
  }
});
onScopeDispose(() => unsubMsg());

onMounted(load);
</script>

<template>
  <section class="webui-failover">
    <header class="webui-failover__head">
      <h1>Failover</h1>
      <!-- `mode` is Tarantool's own setting (replication.failover).
           When the community agent runs on top of failover: off, it
           is the actual leadership driver — Tarantool 3.x ships the
           native supervised agent only in Enterprise Edition, so the
           project bundles an open-source replacement. -->
      <Tag :value="`Tarantool mode: ${mode}`" severity="info" />
      <Tag
        v-if="agent !== null && agent.enabled"
        value="Community agent: active"
        severity="success"
      />
      <button
        v-if="canEditFailover"
        type="button"
        class="webui-failover__btn"
        @click="settingsOpen = true"
      >
        Settings…
      </button>
    </header>
    <p v-if="error" class="webui-failover__error">{{ error }}</p>

    <p class="webui-failover__lede">
      <span v-if="mode === 'off' && agent && agent.enabled">
        Leadership is driven by the <strong>community supervised agent</strong> (below). Tarantool's
        own failover is disabled.
      </span>
      <span v-else-if="mode === 'off'">
        Tarantool's failover is disabled and the community agent is off. Each replicaset uses
        per-instance <code>database.mode</code> to decide who is RW — there is no automatic
        promotion on failure.
      </span>
      <span v-else-if="mode === 'manual'">
        A leader per replicaset is named statically via <code>replicaset.leader</code> in the
        cluster config. Change it in the config editor and commit; there is no automatic failover.
      </span>
      <span v-else-if="mode === 'election'">
        Tarantool's built-in <strong>Raft</strong> elects a leader per replicaset. The per-instance
        state is shown below.
      </span>
      <span v-else-if="mode === 'supervised'">
        Tarantool's <strong>native supervised</strong> mode is enabled (Enterprise Edition). An
        external state provider drives appointments; its endpoints appear in the
        <em>State provider</em> section.
      </span>
      <span v-else
        >Current Tarantool failover mode: <code>{{ mode }}</code
        >.</span
      >
    </p>

    <section v-if="mode === 'election'" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Raft election state</h2>
        <Tag :value="`${elections.length} peer(s)`" severity="secondary" />
      </header>
      <p class="webui-failover__hint">
        One row per instance, snapshotted from <code>box.info.election</code>. The instance whose
        <strong>State</strong> is <code>leader</code> is the current RW peer. Followers vote within
        a <em>term</em>; a term bump means a new election just happened.
      </p>
      <DataTable
        v-if="elections.length > 0"
        :value="elections"
        :loading="loading"
        data-key="instance"
        size="small"
        striped-rows
      >
        <Column field="instance" header="Instance" />
        <Column header="State">
          <template #body="{ data }">
            <Tag :value="data.state ?? '—'" :severity="sev(data.state)" />
          </template>
        </Column>
        <Column field="term" header="Term" />
        <Column field="leader_name" header="Leader">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.leader_name ?? '—' }}</code>
          </template>
        </Column>
      </DataTable>
      <p v-else class="webui-failover__hint">
        No election state reported yet — the cluster is still bootstrapping or peers are
        unreachable.
      </p>
    </section>

    <section v-if="agent && agent.enabled" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Community supervised agent</h2>
        <Tag
          :value="
            agent.is_coordinator
              ? `coordinator (this peer)`
              : `coordinator: ${agent.coordinator ?? '—'}`
          "
          :severity="agent.is_coordinator ? 'success' : 'info'"
        />
        <Tag
          v-if="agent.self_alias"
          :value="`this peer: ${agent.self_alias}`"
          severity="secondary"
        />
      </header>
      <p v-if="agent.last_error" class="webui-failover__err">
        {{ agent.last_error }}
      </p>
      <p class="webui-failover__hint">
        Open-source replacement for Tarantool Enterprise's <code>supervised</code> failover. Every
        peer competes for a <strong>coordinator lease</strong> in etcd (TTL 10 s); the winner probes
        every instance, picks the best leader per replicaset and writes the appointment back into
        etcd. Each peer's <strong>watcher</strong> reads its replicaset's appointment and calls
        <code>box.ctl.promote/demote</code> accordingly.
      </p>
      <h3 class="webui-failover__subhead">Appointments written by the coordinator</h3>
      <p class="webui-failover__hint">
        Source of truth — read straight from
        <code>/tarantool/webui/failover/replicasets/&lt;rs&gt;/leader</code> in etcd, so every
        peer's view here is identical.
      </p>
      <DataTable :value="agent.appointments" data-key="replicaset" size="small" striped-rows>
        <Column field="replicaset" header="Replicaset" />
        <Column header="Appointed leader">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.leader ?? '—' }}</code>
          </template>
        </Column>
        <Column header="Previous">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.previous ?? '—' }}</code>
          </template>
        </Column>
        <Column header="Last written">
          <template #body="{ data }">{{ fmtAge(data.ts) }}</template>
        </Column>
      </DataTable>
      <h3 class="webui-failover__subhead">Watcher (this peer)</h3>
      <p class="webui-failover__hint">
        On <code>{{ agent.self_alias ?? '—' }}</code> (replicaset
        <code>{{ agent.watcher_replicaset ?? '—' }}</code
        >): sees <code>{{ agent.watcher_last_leader ?? '—' }}</code> as the appointed leader. This
        peer is currently
        <strong>{{
          agent.watcher_current_ro === false
            ? 'leader — read-write (owns the synchro queue)'
            : agent.watcher_current_ro === true
              ? 'follower — read-only'
              : 'unknown'
        }}</strong
        >.
      </p>
    </section>

    <section v-if="liveness !== null" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Liveness reports (etcd)</h2>
        <Tag v-if="liveness.reporter_enabled" value="this peer reports" severity="success" />
        <Tag v-else value="this peer does not report" severity="secondary" />
        <Tag
          v-if="liveness.keepalive_interval !== null"
          :value="`keepalive: ${liveness.keepalive_interval}s`"
          severity="secondary"
        />
        <Tag :value="`${liveness.entries.length} record(s)`" severity="info" />
      </header>
      <p class="webui-failover__hint">
        Open-source equivalent of Tarantool Enterprise's top-level
        <code>stateboard</code>. Each peer with
        <code>roles_cfg.webui.state_reporter.enabled: true</code> publishes a JSON snapshot of its
        <code>box.info</code> to <code>/state/by-name/&lt;alias&gt;</code> in etcd, bound to a lease
        so the key vanishes on its own when the process dies. A <strong>stale</strong> row means the
        lease expired without a renewal — usually a crash or a network partition; the iproto poller
        above will agree shortly.
      </p>
      <DataTable
        v-if="liveness.entries.length > 0"
        :value="liveness.entries"
        data-key="alias"
        size="small"
        striped-rows
      >
        <Column field="alias" header="Instance">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.alias ?? '—' }}</code>
          </template>
        </Column>
        <Column header="Freshness">
          <template #body="{ data }">
            <Tag :value="liveLabel(data)" :severity="liveSev(data)" />
          </template>
        </Column>
        <Column header="Age">
          <template #body="{ data }">{{ fmtAgeShort(data.age_seconds) }}</template>
        </Column>
        <Column header="Mode">
          <template #body="{ data }">
            <Tag :value="data.mode ?? '—'" :severity="data.mode === 'rw' ? 'success' : 'info'" />
          </template>
        </Column>
        <Column header="Status">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.status ?? '—' }}</code>
          </template>
        </Column>
        <Column header="RO reason">
          <template #body="{ data }">
            <code v-if="data.ro_reason" class="webui-failover__mono">{{ data.ro_reason }}</code>
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="Hostname">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.hostname ?? '—' }}</code>
          </template>
        </Column>
        <Column header="PID">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.pid ?? '—' }}</code>
          </template>
        </Column>
      </DataTable>
      <p v-else class="webui-failover__hint">
        No liveness records in etcd. Enable the reporter on at least one peer:
        <code>roles_cfg.webui.state_reporter.enabled: true</code>.
      </p>
    </section>

    <section class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Commands history</h2>
        <Tag :value="`${commands.length} recent`" severity="secondary" />
      </header>
      <p class="webui-failover__hint">
        Audit log of every failover-affecting mutation an operator issued through the UI —
        <code>setFailoverMode</code>, <code>promote</code>, leader handoffs and so on. Stored in the
        cluster-wide replicated <code>_webui_failover_commands</code> space; the current leader
        prunes entries older than 30 days.
      </p>
      <DataTable
        :value="commands"
        data-key="id"
        size="small"
        striped-rows
        :paginator="commands.length > 15"
        :rows="15"
      >
        <Column header="When">
          <template #body="{ data }">{{ fmtAge(data.ts) }}</template>
        </Column>
        <Column field="command_type" header="Command">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.command_type }}</code>
          </template>
        </Column>
        <Column header="User">
          <template #body="{ data }">
            <code class="webui-failover__mono">{{ data.user ?? '—' }}</code>
          </template>
        </Column>
        <Column header="Status">
          <template #body="{ data }">
            <Tag :value="data.status" :severity="cmdSev(data.status)" />
          </template>
        </Column>
        <Column header="Latency">
          <template #body="{ data }">{{ cmdLatency(data) }}</template>
        </Column>
        <Column header="Params">
          <template #body="{ data }">
            <code
              v-if="data.params"
              class="webui-failover__mono webui-failover__params"
              :title="data.params"
              >{{ data.params }}</code
            >
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="Error">
          <template #body="{ data }">
            <code v-if="data.error_reason" class="webui-failover__err">{{
              data.error_reason
            }}</code>
            <span v-else>—</span>
          </template>
        </Column>
      </DataTable>
    </section>

    <FailoverSettingsDialog
      v-model:open="settingsOpen"
      :initial-mode="mode"
      :instance-count="instanceCount"
      :initial-agent-enabled="agent !== null && agent.enabled"
      @applied="load"
    />

    <section v-if="sp && sp.kind !== 'none'" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>External state provider</h2>
        <Tag :value="`kind: ${sp.kind}`" severity="info" />
      </header>
      <p class="webui-failover__hint">
        Tarantool's native <code>supervised</code> mode (Enterprise Edition) writes appointments
        through this external state provider. The probe below checks each endpoint via
        <code>HTTP GET /version</code> — only reachability is verified; lease ownership lives inside
        the provider and is not exposed here.
      </p>
      <DataTable :value="sp.endpoints ?? []" data-key="uri" size="small">
        <Column field="uri" header="Endpoint">
          <template #body="{ data }">
            <code>{{ data.uri }}</code>
          </template>
        </Column>
        <Column header="Status">
          <template #body="{ data }">
            <Tag :value="data.status" :severity="epSev(data.status)" />
          </template>
        </Column>
        <Column header="Latency">
          <template #body="{ data }">
            <span v-if="data.latency_ms !== null">{{ data.latency_ms.toFixed(1) }} ms</span>
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="Error">
          <template #body="{ data }">
            <code v-if="data.last_error" class="webui-failover__err">{{ data.last_error }}</code>
            <span v-else>—</span>
          </template>
        </Column>
      </DataTable>
    </section>
  </section>
</template>

<style scoped>
.webui-failover {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-failover__head {
  display: flex;
  align-items: center;
  gap: 1rem;
}
.webui-failover__head h1 {
  margin: 0;
}
.webui-failover__error {
  color: var(--p-message-error-color, #d83535);
}
.webui-failover__mono {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
}
.webui-failover__sp {
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.webui-failover__sp-head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}
.webui-failover__sp-head h2 {
  margin: 0;
  font-size: 1.05rem;
}
.webui-failover__err {
  font-family: var(--webui-font-mono);
  font-size: 0.75rem;
  color: var(--p-message-error-color, #d83535);
}
.webui-failover__lede {
  margin: 0;
  font-size: 0.92rem;
  line-height: 1.4;
  color: var(--webui-text);
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  border-left: 3px solid var(--webui-accent);
  border-radius: var(--webui-radius);
  padding: 0.65rem 0.9rem;
}
.webui-failover__lede code {
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
.webui-failover__subhead {
  margin: 0.25rem 0 0;
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--webui-text-muted);
}
.webui-failover__hint {
  color: var(--webui-text-muted);
  font-size: 0.85rem;
  margin: 0;
}
.webui-failover__hint code {
  font-family: var(--webui-font-mono);
}
.webui-failover__btn {
  padding: 0.4rem 0.85rem;
  font-size: 0.88rem;
  border-radius: 5px;
  border: 1px solid var(--webui-border);
  background: var(--webui-bg);
  color: var(--webui-text);
  cursor: pointer;
}
.webui-failover__btn:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}
.webui-failover__params {
  display: inline-block;
  max-width: 320px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  vertical-align: bottom;
  font-size: 0.78rem;
  color: var(--webui-text-muted);
}
</style>
