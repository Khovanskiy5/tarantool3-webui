<script setup lang="ts">
import { onMounted, reactive } from 'vue';
import { storeToRefs } from 'pinia';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import InputText from 'primevue/inputtext';
import Button from 'primevue/button';
import Tag from 'primevue/tag';

import { useAuditStore } from '@/entities/audit-entry';
import { downloadExportedAudit } from '@/features/audit-export';
import { getClient } from '@/shared/api/graphql';

interface ChainVerifyResult {
  ok: boolean;
  scanned: number;
  seals: number;
  broken_at?: number | null;
  expected_hash?: string | null;
  actual_hash?: string | null;
  reason?: string | null;
}

const store = useAuditStore();
const { entries, pending, error, hasMore } = storeToRefs(store);

const filter = reactive({
  user: '',
  action: '',
  scope: '',
  // Prefix match (e.g. `cluster.`) is mutually exclusive with the
  // exact-match `action` field in the UI: the chip handlers toggle
  // which one is populated. Backend filters AND them, so we keep
  // the dichotomy at the UI level so the operator never sees
  // overlapping criteria.
  action_prefix: '',
});

// Curated quick-filter chips for the most operationally interesting
// actions. Order: most-used first. New action types added to other
// audit-emitting code paths should land here too so operators have a
// one-click filter without remembering string names.
//
// Presets either pin an exact action (`exact`) or a prefix
// (`prefix`); the latter groups a family of related mutations under
// a single chip. The audit page only ever has one preset active at a
// time so the operator can keep typing into the user / scope fields
// without losing the family selection.
type ActionPreset =
  | { label: string; exact: string }
  | { label: string; prefix: string };

const actionPresets: ActionPreset[] = [
  { label: 'Cluster ops',       prefix: 'cluster.' },
  { label: 'Config rollback',   exact:  'config.rollback' },
  { label: 'Config commit',     exact:  'config.commit' },
  { label: 'Login',             exact:  'auth.login' },
  { label: 'Login failed',      exact:  'auth.login_failed' },
  { label: 'Logout',            exact:  'auth.logout' },
  { label: 'RBAC denied',       exact:  'rbac.denied' },
  { label: 'Console (Lua)',     exact:  'eval.lua' },
  { label: 'Console (SQL)',     exact:  'eval.sql' },
];

const buildFilter = () => ({
  user:          filter.user.trim()          || undefined,
  action:        filter.action.trim()        || undefined,
  action_prefix: filter.action_prefix.trim() || undefined,
  scope:         filter.scope.trim()         || undefined,
});

const apply = () => { store.load(buildFilter()); };
const loadMore = () => { store.load(buildFilter(), { append: true }); };
const exportNow = () => { downloadExportedAudit(buildFilter()); };
const resetFilters = () => {
  filter.user = '';
  filter.action = '';
  filter.action_prefix = '';
  filter.scope = '';
  store.load({});
};
const setPreset = (preset: ActionPreset) => {
  if ('exact' in preset) {
    filter.action = preset.exact;
    filter.action_prefix = '';
  } else {
    filter.action = '';
    filter.action_prefix = preset.prefix;
  }
  store.load(buildFilter());
};

const fmtTs = (us: number) => new Date(Math.floor(us / 1000)).toISOString();

// ── audit chain verifier (Phase 4 Task 4.3) ────────────────────────
//
// Operator-triggered: clicking "Verify chain" walks the
// `_webui_audit` chain on the local instance and returns a
// success/failure result. A failed chain renders a destructive
// red Tag — that's the cue to investigate (corruption was
// inserted between the chain's last seal and the first broken
// row).

import { ref } from 'vue';

const VERIFY_Q = /* GraphQL */ `
  query AuditChainVerify {
    verifyAuditChain {
      ok scanned seals broken_at expected_hash actual_hash reason
    }
  }
`;

const verifying = ref(false);
const verifyResult = ref<ChainVerifyResult | null>(null);

async function verifyChain() {
  verifying.value = true;
  try {
    const res = await getClient()
      .query<{ verifyAuditChain: ChainVerifyResult }>(
        VERIFY_Q, {}, { requestPolicy: 'network-only' })
      .toPromise();
    if (res.error) {
      verifyResult.value = {
        ok: false, scanned: 0, seals: 0,
        reason: res.error.message,
      };
      return;
    }
    verifyResult.value = res.data?.verifyAuditChain ?? null;
  } finally {
    verifying.value = false;
  }
}

onMounted(() => { store.load({}); });
</script>

<template>
  <section class="webui-audit">
    <header class="webui-audit__head">
      <h1>Audit log</h1>
      <div class="webui-audit__head-actions">
        <Tag
          v-if="verifyResult"
          :severity="verifyResult.ok ? 'success' : 'danger'"
          :value="verifyResult.ok
            ? `chain OK — ${verifyResult.scanned} rows, ${verifyResult.seals} seal(s)`
            : `chain BROKEN — ${verifyResult.reason ?? 'see broken_at'}`"
          class="webui-audit__chain-badge"
        />
        <Button
          size="small"
          icon="pi pi-shield"
          label="Verify chain"
          severity="info"
          text
          :loading="verifying"
          @click="verifyChain"
        />
        <Button
          size="small"
          icon="pi pi-download"
          label="Export JSON"
          @click="exportNow"
        />
      </div>
    </header>

    <div class="webui-audit__presets">
      <span class="webui-audit__presets-label">Quick filters:</span>
      <button
        v-for="preset in actionPresets"
        :key="preset.label"
        type="button"
        :class="[
          'webui-audit__preset',
          {
            'webui-audit__preset--active':
              ('exact' in preset && filter.action === preset.exact)
              || ('prefix' in preset && filter.action_prefix === preset.prefix),
          },
        ]"
        :title="
          'exact' in preset
            ? `Filter by action ${preset.exact}`
            : `Filter by action prefix ${preset.prefix}`
        "
        @click="setPreset(preset)"
      >
        {{ preset.label }}
      </button>
      <button
        v-if="filter.user || filter.action || filter.action_prefix || filter.scope"
        type="button"
        class="webui-audit__reset"
        @click="resetFilters"
      >
        Reset
      </button>
    </div>

    <form class="webui-audit__filters" @submit.prevent="apply">
      <InputText v-model="filter.user" placeholder="user" />
      <InputText v-model="filter.action" placeholder="action (e.g. auth.login)" />
      <InputText v-model="filter.scope" placeholder="scope" />
      <Button type="submit" size="small" label="Apply" />
    </form>

    <p v-if="error" class="webui-audit__error">{{ error }}</p>

    <DataTable
      :value="entries"
      :loading="pending"
      data-key="id"
      size="small"
      striped-rows
      table-style="min-width: 50rem"
    >
      <Column header="When" :body-style="{ width: '14rem' }">
        <template #body="{ data }">{{ fmtTs(data.ts) }}</template>
      </Column>
      <Column field="user" header="User" :body-style="{ width: '10rem' }" />
      <Column field="action" header="Action" :body-style="{ width: '14rem' }" />
      <Column field="scope" header="Scope" :body-style="{ width: '10rem' }" />
      <Column header="Payload">
        <template #body="{ data }">
          <code v-if="data.payload" class="webui-audit__payload">{{ data.payload }}</code>
          <span v-else class="webui-audit__muted">—</span>
        </template>
      </Column>
    </DataTable>

    <div class="webui-audit__footer">
      <Button
        v-if="hasMore"
        size="small"
        text
        label="Load more"
        @click="loadMore"
      />
    </div>
  </section>
</template>

<style scoped>
.webui-audit { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; }
.webui-audit__head { display: flex; justify-content: space-between; align-items: center; }
.webui-audit__presets {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  align-items: center;
  font-size: 0.8rem;
}
.webui-audit__presets-label {
  color: var(--webui-text-muted, #8a93a6);
  margin-right: 0.25rem;
}
.webui-audit__preset {
  font-size: 0.75rem;
  padding: 0.2rem 0.6rem;
  border-radius: 999px;
  border: 1px solid var(--webui-border, #2a2f3a);
  background: var(--webui-bg-elevated, #161a23);
  color: inherit;
  cursor: pointer;
  font-family: var(--webui-font-mono, monospace);
}
.webui-audit__preset:hover {
  border-color: var(--webui-accent, #4ea8de);
}
.webui-audit__preset--active {
  background: var(--webui-accent, #4ea8de);
  color: var(--webui-bg, #11141d);
  border-color: var(--webui-accent, #4ea8de);
}
.webui-audit__reset {
  font-size: 0.75rem;
  padding: 0.2rem 0.6rem;
  border-radius: 999px;
  background: transparent;
  border: 1px dashed var(--webui-border, #2a2f3a);
  color: var(--webui-text-muted, #8a93a6);
  cursor: pointer;
}
.webui-audit__reset:hover {
  border-color: var(--webui-danger, #c0392b);
  color: var(--webui-danger, #c0392b);
}
.webui-audit__filters { display: flex; gap: 0.5rem; }
.webui-audit__error { color: var(--p-message-error-color, #d83535); }
.webui-audit__payload { font-family: var(--webui-font-mono); font-size: 0.8rem; }
.webui-audit__muted { color: var(--webui-text-muted); }
.webui-audit__footer { display: flex; justify-content: center; }
</style>
