<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { storeToRefs } from 'pinia';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import InputText from 'primevue/inputtext';
import Button from 'primevue/button';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

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
type ActionPreset = { label: string; exact: string } | { label: string; prefix: string };

const actionPresets: ActionPreset[] = [
  { label: 'Cluster ops', prefix: 'cluster.' },
  { label: 'Config rollback', exact: 'config.rollback' },
  { label: 'Config commit', exact: 'config.commit' },
  { label: 'Login', exact: 'auth.login' },
  { label: 'Login failed', exact: 'auth.login_failed' },
  { label: 'Logout', exact: 'auth.logout' },
  { label: 'RBAC denied', exact: 'rbac.denied' },
  { label: 'Console (Lua)', exact: 'eval.lua' },
  { label: 'Console (SQL)', exact: 'eval.sql' },
];

const buildFilter = () => ({
  user: filter.user.trim() || undefined,
  action: filter.action.trim() || undefined,
  action_prefix: filter.action_prefix.trim() || undefined,
  scope: filter.scope.trim() || undefined,
});

const apply = () => {
  store.load(buildFilter());
};
const loadMore = () => {
  store.load(buildFilter(), { append: true });
};
const exportNow = () => {
  downloadExportedAudit(buildFilter());
};
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
const isPresetActive = (preset: ActionPreset): boolean =>
  ('exact' in preset && filter.action === preset.exact) ||
  ('prefix' in preset && filter.action_prefix === preset.prefix);

const hasAnyFilter = (): boolean =>
  filter.user !== '' || filter.action !== '' || filter.action_prefix !== '' || filter.scope !== '';

const fmtTs = (us: number) => new Date(Math.floor(us / 1000)).toISOString();

// ── audit chain verifier (Phase 4 Task 4.3) ────────────────────────
//
// Operator-triggered: clicking "Verify chain" walks the
// `_webui_audit` chain on the local instance and returns a
// success/failure result. A failed chain renders a destructive
// red Tag — that's the cue to investigate (corruption was
// inserted between the chain's last seal and the first broken
// row).
const VERIFY_Q = /* GraphQL */ `
  query AuditChainVerify {
    verifyAuditChain {
      ok
      scanned
      seals
      broken_at
      expected_hash
      actual_hash
      reason
    }
  }
`;

const verifying = ref(false);
const verifyResult = ref<ChainVerifyResult | null>(null);

async function verifyChain() {
  verifying.value = true;
  try {
    const res = await getClient()
      .query<{
        verifyAuditChain: ChainVerifyResult;
      }>(VERIFY_Q, {}, { requestPolicy: 'network-only' })
      .toPromise();
    if (res.error) {
      verifyResult.value = {
        ok: false,
        scanned: 0,
        seals: 0,
        reason: res.error.message,
      };
      return;
    }
    verifyResult.value = res.data?.verifyAuditChain ?? null;
  } finally {
    verifying.value = false;
  }
}

onMounted(() => {
  store.load({});
});
</script>

<template>
  <section class="webui-audit">
    <header class="webui-audit__head">
      <h1>Audit log</h1>
      <Tag :value="`${entries.length} entries`" severity="secondary" />
      <Tag
        v-if="verifyResult"
        :severity="verifyResult.ok ? 'success' : 'danger'"
        :value="
          verifyResult.ok
            ? `chain OK — ${verifyResult.scanned} rows, ${verifyResult.seals} seal(s)`
            : `chain BROKEN — ${verifyResult.reason ?? 'see broken_at'}`
        "
      />
      <div class="webui-audit__head-actions">
        <Button
          size="small"
          icon="pi pi-shield"
          label="Verify chain"
          severity="info"
          text
          :loading="verifying"
          @click="verifyChain"
        />
        <Button size="small" icon="pi pi-download" label="Export JSON" @click="exportNow" />
      </div>
    </header>

    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>

    <!-- Quick-filter chip row. Buttons themed as text-pill so the
         active preset is visually distinct without a bespoke `.preset`
         class — `severity="primary"` is PrimeVue's "selected" cue. -->
    <fieldset class="webui-audit__bar webui-audit__bar--presets">
      <legend class="webui-audit__legend">Quick filters</legend>
      <Button
        v-for="preset in actionPresets"
        :key="preset.label"
        :label="preset.label"
        :severity="isPresetActive(preset) ? 'primary' : 'secondary'"
        :outlined="!isPresetActive(preset)"
        size="small"
        :title="
          'exact' in preset
            ? `Filter by action ${preset.exact}`
            : `Filter by action prefix ${preset.prefix}`
        "
        @click="setPreset(preset)"
      />
      <Button
        v-if="hasAnyFilter()"
        label="Reset"
        icon="pi pi-times"
        severity="secondary"
        text
        size="small"
        @click="resetFilters"
      />
    </fieldset>

    <!-- Per-column text filters with explicit r-field labels so the
         operator does not have to guess what each input narrows. -->
    <form class="webui-audit__bar webui-audit__bar--filters" @submit.prevent="apply">
      <div class="webui-audit__field">
        <label for="audit-user">User</label>
        <InputText
          id="audit-user"
          v-model="filter.user"
          size="small"
          placeholder="alice"
          @keyup.enter="apply"
        />
      </div>
      <div class="webui-audit__field">
        <label for="audit-action">Action</label>
        <InputText
          id="audit-action"
          v-model="filter.action"
          size="small"
          placeholder="e.g. auth.login"
          @keyup.enter="apply"
        />
      </div>
      <div class="webui-audit__field">
        <label for="audit-scope">Scope</label>
        <InputText
          id="audit-scope"
          v-model="filter.scope"
          size="small"
          placeholder="session"
          @keyup.enter="apply"
        />
      </div>
      <div class="webui-audit__apply">
        <Button type="submit" size="small" icon="pi pi-filter" label="Apply" />
      </div>
    </form>

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
      <Button v-if="hasMore" size="small" text label="Load more" @click="loadMore" />
    </div>
  </section>
</template>

<style scoped>
.webui-audit {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-audit__head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  flex-wrap: wrap;
}
.webui-audit__head h1 {
  margin: 0;
}
.webui-audit__head-actions {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  /* Push action buttons to the right edge of the wrapped header. */
  margin-left: auto;
}

/* Shared bar surface for the two control rows (presets + filters).
   Painted from PrimeVue tokens so the theme picker stays in charge. */
.webui-audit__bar {
  display: flex;
  align-items: flex-end;
  gap: 0.5rem;
  flex-wrap: wrap;
  padding: 0.6rem 0.8rem;
  background: var(--p-content-background);
  border: 1px solid var(--p-content-border-color);
  border-radius: var(--p-content-border-radius, 6px);
  margin: 0;
}
.webui-audit__bar--presets {
  align-items: center;
}
.webui-audit__legend {
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color);
  padding: 0 0.4rem;
}

/* Same r-field shape used by the other pages — uppercase label on
   top, control underneath. Keeps the audit filter row consistent
   with the issues / logs / config-editor toolbars. */
.webui-audit__field {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  min-width: 12rem;
}
.webui-audit__field > label {
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--p-text-muted-color);
}
.webui-audit__field > :deep(input.p-inputtext) {
  width: 100%;
}
.webui-audit__apply {
  display: inline-flex;
  align-items: flex-end;
  margin-left: auto;
}

.webui-audit__payload {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
}
.webui-audit__muted {
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-audit__footer {
  display: flex;
  justify-content: center;
}
</style>
