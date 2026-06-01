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

const mode = ref<string>('');
const elections = ref<Election[]>([]);
const sp = ref<SPStatus | null>(null);
const agent = ref<AgentStatus | null>(null);
const commands = ref<FailoverCommand[]>([]);
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
      elections { instance state term leader_name }
    }
    failoverStateProviderStatus {
      kind mode lease_active coordinator
      endpoints { uri status latency_ms last_error }
    }
    failoverAgentStatus {
      enabled self_alias coordinator is_coordinator lease_id last_error
      watcher_replicaset watcher_last_leader watcher_current_ro
      appointments { replicaset leader previous ts }
    }
    failoverCommands(limit: 50) {
      entries {
        id ts command_type params status user coordinator
        taken_at completed_at error_reason
      }
    }
    cluster {
      servers(limit: 50) { totalCount }
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient().query<{
    failover: { mode: string; elections: Election[] };
    failoverStateProviderStatus: SPStatus;
    failoverAgentStatus: AgentStatus;
    failoverCommands: { entries: FailoverCommand[] };
    cluster: { servers: { totalCount: number } };
  }>(FAILOVER_Q, {}, { requestPolicy: 'network-only' }).toPromise();
  if (res.error) { error.value = res.error.message; loading.value = false; return; }
  mode.value = res.data?.failover?.mode ?? 'unknown';
  elections.value = res.data?.failover?.elections ?? [];
  sp.value = res.data?.failoverStateProviderStatus ?? null;
  agent.value = res.data?.failoverAgentStatus ?? null;
  commands.value = res.data?.failoverCommands?.entries ?? [];
  instanceCount.value = res.data?.cluster?.servers?.totalCount ?? 0;
  loading.value = false;
};

const fmtAge = (ts: number | null): string => {
  if (ts == null) return '—';
  const dt = new Date(ts * 1000);
  return dt.toISOString().replace('T', ' ').slice(0, 19) + 'Z';
};

const sev = (state: string | null) => state === 'leader' ? 'success' : state === 'follower' ? 'info' : 'warn';
const epSev = (status: string) => status === 'ok' ? 'success' : 'danger';
const cmdSev = (status: string) => {
  if (status === 'success') return 'success';
  if (status === 'failed') return 'danger';
  if (status === 'taken') return 'info';
  return 'secondary';
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
      <Tag :value="`mode: ${mode}`" severity="info" />
      <!-- The `mode` badge tells you only the Raft setting. When
           the open-source supervised agent is running on top, that
           is the actual leadership driver — surface a second badge
           so the page header reflects reality. -->
      <Tag
        v-if="agent !== null && agent.enabled"
        value="agent: on"
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

    <DataTable
      v-if="mode === 'election' && elections.length > 0"
      :value="elections" :loading="loading"
      data-key="instance" size="small" striped-rows
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
    <p
      v-else-if="mode !== 'election'"
      class="webui-failover__hint"
    >
      Built-in Raft election is disabled (mode is <code>{{ mode }}</code>).
      Leadership is driven by
      <span v-if="mode === 'off'">per-instance <code>database.mode</code> +
        the agent below (if enabled).</span>
      <span v-else-if="mode === 'manual'">the <code>replicaset.leader</code>
        field in cluster config — change it via the config editor and
        commit.</span>
      <span v-else>an external state provider.</span>
    </p>

    <section v-if="agent && agent.enabled" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Open-source supervised agent</h2>
        <Tag
          :value="`coordinator: ${agent.coordinator ?? '—'}`"
          :severity="agent.is_coordinator ? 'success' : 'info'"
        />
        <Tag
          v-if="agent.self_alias"
          :value="`self: ${agent.self_alias}`"
          severity="secondary"
        />
      </header>
      <p v-if="agent.last_error" class="webui-failover__err">
        {{ agent.last_error }}
      </p>
      <p class="webui-failover__hint">
        etcd-based lease elects one coordinator. The coordinator probes
        every peer and writes per-replicaset appointments under
        <code>/tarantool/webui/failover/replicasets/&lt;rs&gt;/leader</code>;
        each instance's watcher reconciles <code>box.cfg.read_only</code>
        via <code>box.ctl.promote/demote</code>. Lease TTL: 10s.
      </p>
      <DataTable
        :value="agent.appointments"
        data-key="replicaset"
        size="small"
        striped-rows
      >
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
      <p class="webui-failover__hint">
        Watcher on <code>{{ agent.self_alias ?? '—' }}</code>: replicaset
        <code>{{ agent.watcher_replicaset ?? '—' }}</code>, last seen leader
        <code>{{ agent.watcher_last_leader ?? '—' }}</code>, currently
        <strong>{{ agent.watcher_current_ro === false ? 'leader (RW)'
          : agent.watcher_current_ro === true ? 'follower (RO)'
            : 'unknown' }}</strong>.
      </p>
    </section>

    <section class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>Commands history</h2>
        <Tag :value="`${commands.length} recent`" severity="secondary" />
      </header>
      <p class="webui-failover__hint">
        Every operator-issued cluster mutation lands here via the
        <code>_webui_failover_commands</code> replicated sync space. The
        leader's retention fiber prunes rows older than 30 days.
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
            >{{ data.params }}</code>
            <span v-else>—</span>
          </template>
        </Column>
        <Column header="Error">
          <template #body="{ data }">
            <code v-if="data.error_reason" class="webui-failover__err">{{ data.error_reason }}</code>
            <span v-else>—</span>
          </template>
        </Column>
      </DataTable>
    </section>

    <FailoverSettingsDialog
      :open="settingsOpen"
      :initial-mode="mode"
      :instance-count="instanceCount"
      :initial-agent-enabled="agent !== null && agent.enabled"
      @close="settingsOpen = false"
      @applied="load"
    />

    <section v-if="sp && sp.kind !== 'none'" class="webui-failover__sp">
      <header class="webui-failover__sp-head">
        <h2>State provider</h2>
        <Tag :value="`kind: ${sp.kind}`" severity="info" />
      </header>
      <DataTable :value="sp.endpoints ?? []" data-key="uri" size="small">
        <Column field="uri" header="Endpoint">
          <template #body="{ data }"><code>{{ data.uri }}</code></template>
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
.webui-failover { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-failover__head { display: flex; align-items: center; gap: 1rem; }
.webui-failover__head h1 { margin: 0; }
.webui-failover__error { color: var(--p-message-error-color, #d83535); }
.webui-failover__mono { font-family: var(--webui-font-mono); font-size: 0.8rem; }
.webui-failover__sp { background: var(--webui-bg-elevated); border: 1px solid var(--webui-border); border-radius: var(--webui-radius); padding: 1rem; display: flex; flex-direction: column; gap: 0.75rem; }
.webui-failover__sp-head { display: flex; align-items: center; gap: 0.75rem; }
.webui-failover__sp-head h2 { margin: 0; font-size: 1.05rem; }
.webui-failover__err { font-family: var(--webui-font-mono); font-size: 0.75rem; color: var(--p-message-error-color, #d83535); }
.webui-failover__hint { color: var(--webui-text-muted); font-size: 0.85rem; margin: 0; }
.webui-failover__hint code { font-family: var(--webui-font-mono); }
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
