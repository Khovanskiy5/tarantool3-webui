<script setup lang="ts">
import { onMounted, ref, computed } from 'vue';
import Button from 'primevue/button';
import Message from 'primevue/message';
import Tag from 'primevue/tag';

import { getClient } from '@/shared/api/graphql';
import { DestructiveActionDialog } from '@/shared/ui/destructive-action-dialog';
import { CodeEditor } from '@/widgets/code-editor';
import HistoryPanel from './HistoryPanel.vue';
import DiffViewer from './DiffViewer.vue';

interface CurrentCfg {
  yaml: string;
  revision: number | null;
  source: string;
}
interface DiffOp {
  op: string;
  path: string;
  from?: string | null;
  to?: string | null;
}
interface PrepareRes {
  prepared_id: string;
  expires_at: number;
  diff: DiffOp[] | null;
  warnings: { path: string; message: string }[] | null;
}
interface CommitRes {
  revision: number;
  applied: boolean;
  message: string | null;
}
interface RevisionFull {
  revision: number;
  yaml: string;
  ts: number | null;
  user: string | null;
  action: string | null;
}

const yaml = ref('');
const source = ref('');
const revision = ref<number | null>(null);
const loading = ref(false);
const validating = ref(false);
const preparing = ref(false);
const committing = ref(false);
const rollingBack = ref(false);
const rollbackTarget = ref<number | null>(null);
const forceApplying = ref(false);
const forceApplyTarget = ref<number | null>(null);
const error = ref<string | null>(null);
const info = ref<string | null>(null);
const validationIssues = ref<{ path: string; message: string }[]>([]);
const preparedId = ref<string | null>(null);
const diff = ref<DiffOp[]>([]);

// History panel ref so the parent can imperatively .refresh() after a
// commit/rollback lands a new entry on the timeline.
const historyPanelRef = ref<InstanceType<typeof HistoryPanel> | null>(null);

// DiffViewer state — driven by HistoryPanel's request-diff event.
const diffViewer = ref({
  open: false,
  title: '',
  originalLabel: '',
  modifiedLabel: '',
  original: '',
  modified: '',
});

const Q_CURRENT = /* GraphQL */ `
  query Cfg {
    config {
      yaml
      revision
      source
    }
  }
`;
const Q_REVISION = /* GraphQL */ `
  query CfgRev($revision: Long!) {
    configRevision(revision: $revision) {
      revision
      yaml
      ts
      user
      action
    }
  }
`;
const M_VALIDATE = /* GraphQL */ `
  mutation Validate($yaml: String!) {
    validateConfig(yaml: $yaml) {
      issues {
        path
        message
      }
    }
  }
`;
const M_PROPOSE = /* GraphQL */ `
  mutation Propose($yaml: String!) {
    proposeConfig(yaml: $yaml) {
      prepared_id
      expires_at
      diff {
        op
        path
        from
        to
      }
      warnings {
        path
        message
      }
    }
  }
`;
const M_COMMIT = /* GraphQL */ `
  mutation Commit($id: String!) {
    commitConfig(prepared_id: $id) {
      revision
      applied
      message
    }
  }
`;
const M_ABORT = /* GraphQL */ `
  mutation Abort($id: String!) {
    abortConfig(prepared_id: $id) {
      applied
      message
    }
  }
`;
const M_ROLLBACK = /* GraphQL */ `
  mutation Rollback($revision: Long!) {
    rollbackConfig(revision: $revision) {
      revision
      applied
      message
    }
  }
`;
const M_FORCE_APPLY = /* GraphQL */ `
  mutation ForceApply($revision: Long!) {
    forceReapplyConfig(revision: $revision) {
      results {
        instance
        ok
        err
      }
      rollback_to
      rollback_revision
      rollback_message
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient()
    .query<{ config: CurrentCfg }>(
      Q_CURRENT,
      {},
      {
        requestPolicy: 'network-only',
      },
    )
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loading.value = false;
    return;
  }
  yaml.value = res.data?.config?.yaml ?? '';
  source.value = res.data?.config?.source ?? '';
  revision.value = res.data?.config?.revision ?? null;
  loading.value = false;
};

const validate = async () => {
  validating.value = true;
  error.value = null;
  info.value = null;
  validationIssues.value = [];
  const res = await getClient()
    .mutation<{
      validateConfig: { issues: { path: string; message: string }[] };
    }>(M_VALIDATE, { yaml: yaml.value })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    validating.value = false;
    return;
  }
  validationIssues.value = res.data?.validateConfig?.issues ?? [];
  if (validationIssues.value.length === 0) info.value = 'No validation issues.';
  validating.value = false;
};

const preview = async () => {
  preparing.value = true;
  error.value = null;
  info.value = null;
  diff.value = [];
  const res = await getClient()
    .mutation<{ proposeConfig: PrepareRes }>(M_PROPOSE, { yaml: yaml.value })
    .toPromise();
  if (res.error) {
    // Backend rejects a no-op submission with the typed NO_CHANGES
    // error class — render it as a neutral info banner, not a red
    // error. Apply stays disabled because preparedId is still null.
    // We read `extensions.code` rather than substring-matching the
    // public message: the message is human-readable / i18n'able and
    // can drift, but the code is the stable contract.
    const codes =
      res.error.graphQLErrors?.map(
        (e) => (e as { extensions?: { code?: string } }).extensions?.code ?? '',
      ) ?? [];
    if (codes.includes('NO_CHANGES')) {
      info.value = 'No changes vs current revision — nothing to commit.';
    } else {
      error.value = res.error.message;
    }
    preparing.value = false;
    return;
  }
  const r = res.data?.proposeConfig;
  if (r) {
    preparedId.value = r.prepared_id;
    diff.value = r.diff ?? [];
    info.value = `Prepared ${r.prepared_id} (expires at ${new Date(r.expires_at * 1000).toLocaleTimeString()}). ${diff.value.length} diff ops.`;
  }
  preparing.value = false;
};

const apply = async () => {
  if (preparedId.value == null) return;
  committing.value = true;
  error.value = null;
  const res = await getClient()
    .mutation<{ commitConfig: CommitRes }>(M_COMMIT, { id: preparedId.value })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    committing.value = false;
    return;
  }
  const r = res.data?.commitConfig;
  if (r?.applied) {
    info.value = r.message ?? `Applied. New revision ${r.revision}.`;
    preparedId.value = null;
    diff.value = [];
    await load();
    historyPanelRef.value?.refresh();
  } else {
    error.value = r?.message ?? 'commit not applied';
  }
  committing.value = false;
};

const abort = async () => {
  if (preparedId.value == null) return;
  await getClient().mutation(M_ABORT, { id: preparedId.value }).toPromise();
  preparedId.value = null;
  diff.value = [];
  info.value = 'Prepared state discarded.';
};

const download = async () => {
  try {
    const blob = await fetch('/api/config/download', { credentials: 'same-origin' }).then((r) =>
      r.blob(),
    );
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'cluster.yaml';
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  } catch (e) {
    error.value = (e as Error).message;
  }
};

// Fetch a historical YAML body via configRevision query. Returns the
// payload on success, surfaces REVISION_NOT_FOUND as a parent banner
// instead of throwing — the timeline can legitimately race the cap
// (worst case: another commit ages out the row between list and read).
const fetchRevisionYaml = async (rev: number): Promise<string | null> => {
  const res = await getClient()
    .query<{ configRevision: RevisionFull }>(
      Q_REVISION,
      { revision: rev },
      {
        requestPolicy: 'network-only',
      },
    )
    .toPromise();
  if (res.error) {
    // Surface a friendly message for the most common case (aged-out
    // beyond MAX_HISTORY) before bubbling the raw text.
    const msg = res.error.message;
    if (msg.includes('REVISION_NOT_FOUND')) {
      error.value = `Revision #${rev} no longer available — aged out beyond MAX_HISTORY.`;
    } else {
      error.value = msg;
    }
    return null;
  }
  return res.data?.configRevision?.yaml ?? null;
};

const onSelectRevision = async (rev: number) => {
  error.value = null;
  info.value = null;
  const body = await fetchRevisionYaml(rev);
  if (body == null) return;
  yaml.value = body;
  info.value = `Loaded revision #${rev} into the editor. Review and click "Preview diff" to commit it as the new version.`;
};

const onRequestDiff = async (rev: number, against: 'prev' | 'current') => {
  error.value = null;
  const target = await fetchRevisionYaml(rev);
  if (target == null) return;

  if (against === 'current') {
    diffViewer.value = {
      open: true,
      title: `Diff: revision #${rev} → current (#${revision.value ?? '?'})`,
      originalLabel: `Revision #${rev}`,
      modifiedLabel: `Current (revision #${revision.value ?? '?'})`,
      original: target,
      modified: yaml.value,
    };
    return;
  }

  // "Diff vs prev": find the predecessor on the timeline and pull it.
  // We rely on HistoryPanel having loaded the page already — the prev
  // pointer is recoverable from its own list, but the parent does the
  // fetch to keep the prop surface narrow.
  const prevYaml = await fetchPreviousRevisionYaml(rev);
  if (prevYaml == null) {
    error.value = `Cannot diff #${rev} vs previous — no earlier revision available.`;
    return;
  }
  diffViewer.value = {
    open: true,
    title: `Diff: previous → #${rev}`,
    originalLabel: 'Previous revision',
    modifiedLabel: `Revision #${rev}`,
    original: prevYaml,
    modified: target,
  };
};

const Q_HISTORY_MINIMAL = /* GraphQL */ `
  query CfgHistoryMin {
    configHistory(limit: 200) {
      revisions {
        revision
      }
    }
  }
`;

const fetchPreviousRevisionYaml = async (rev: number): Promise<string | null> => {
  const res = await getClient()
    .query<{
      configHistory: { revisions: { revision: number }[] };
    }>(Q_HISTORY_MINIMAL, {}, { requestPolicy: 'network-only' })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    return null;
  }
  const list = res.data?.configHistory?.revisions ?? [];
  const sorted = [...list].sort((a, b) => a.revision - b.revision);
  let prev: number | null = null;
  for (const r of sorted) {
    if (r.revision < rev) prev = r.revision;
  }
  if (prev == null) return null;
  return await fetchRevisionYaml(prev);
};

// Rollback is destructive — gated behind the shared
// DestructiveActionDialog, same pattern as force-apply below. The
// dialog forces the operator to type the revision number verbatim
// before Confirm enables, which kills the misclick failure mode the
// previous `window.confirm` had.
const onRequestRollback = (rev: number) => {
  rollbackTarget.value = rev;
};
const cancelRollback = () => {
  if (rollingBack.value) return;
  rollbackTarget.value = null;
};
const confirmRollback = async () => {
  const rev = rollbackTarget.value;
  if (rev == null) return;
  rollingBack.value = true;
  error.value = null;
  info.value = null;
  const res = await getClient()
    .mutation<{ rollbackConfig: CommitRes }>(M_ROLLBACK, { revision: rev })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
  } else {
    const r = res.data?.rollbackConfig;
    if (r?.applied) {
      info.value = r.message ?? `Rolled back to #${rev}. New revision ${r.revision}.`;
      preparedId.value = null;
      diff.value = [];
      await load();
      historyPanelRef.value?.refresh();
    } else {
      error.value = r?.message ?? 'rollback not applied';
    }
  }
  rollingBack.value = false;
  rollbackTarget.value = null;
};

// Force apply revision N (Task 5.17). Composes through the
// backend's `forceReapplyConfig(revision)` — which rolls back to N
// then fans out config:reload — so the SPA only emits one
// mutation and lets the backend handle the choreography.
//
// We gate the action behind the shared DestructiveActionDialog so
// a single misclick cannot re-apply the wrong revision. The
// dialog requires the operator to type the revision number
// verbatim before Confirm enables.
const onRequestForceApply = (rev: number) => {
  forceApplyTarget.value = rev;
};
const cancelForceApply = () => {
  if (forceApplying.value) return;
  forceApplyTarget.value = null;
};
const confirmForceApply = async () => {
  const rev = forceApplyTarget.value;
  if (rev == null) return;
  forceApplying.value = true;
  error.value = null;
  info.value = null;
  const res = await getClient()
    .mutation<{
      forceReapplyConfig: {
        results: { instance: string; ok: boolean; err: string | null }[];
        rollback_to: number | null;
        rollback_revision: number | null;
        rollback_message: string | null;
      };
    }>(M_FORCE_APPLY, { revision: rev })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
  } else {
    const r = res.data?.forceReapplyConfig;
    if (r) {
      info.value =
        r.rollback_message ??
        `Force-applied revision ${rev}; new commit #${r.rollback_revision ?? '?'}.`;
      await load();
      historyPanelRef.value?.refresh();
    }
  }
  forceApplying.value = false;
  forceApplyTarget.value = null;
};

const hasPrepared = computed(() => preparedId.value != null);

onMounted(load);
</script>

<template>
  <section class="webui-cfg">
    <header class="webui-cfg__head">
      <div class="webui-cfg__title-block">
        <h1>Configuration editor</h1>
        <div class="webui-cfg__title-meta">
          <Tag :value="`source: ${source || '—'}`" severity="secondary" />
          <Tag :value="`revision: ${revision ?? 0}`" severity="info" />
        </div>
      </div>
      <div class="webui-cfg__buttons">
        <Button outlined icon="pi pi-download" size="small" label="Download" @click="download" />
        <Button
          outlined
          icon="pi pi-refresh"
          size="small"
          label="Reload"
          :loading="loading"
          @click="load"
        />
      </div>
    </header>

    <!-- The split is just editor + history so both columns share the
         same row height. Actions / messages / validation /
         diff sections sit *below* the split (full width) so the
         History panel can stay flush with the editor's bottom edge
         rather than stretching past it to cover those rows. -->
    <div class="webui-cfg__split">
      <!-- Editor stretches to fill the row height the grid gives it. -->
      <div class="webui-cfg__editor-slot">
        <CodeEditor v-model="yaml" height="100%" />
      </div>

      <HistoryPanel
        ref="historyPanelRef"
        :current-revision="revision"
        class="webui-cfg__history"
        @select-revision="onSelectRevision"
        @request-diff="onRequestDiff"
        @request-rollback="onRequestRollback"
        @request-force-apply="onRequestForceApply"
      />
    </div>

    <div class="webui-cfg__actions">
      <Button
        icon="pi pi-check"
        size="small"
        label="Validate"
        :loading="validating"
        @click="validate"
      />
      <Button
        icon="pi pi-eye"
        size="small"
        label="Preview diff"
        :loading="preparing"
        @click="preview"
      />
      <Button
        v-if="hasPrepared"
        severity="success"
        icon="pi pi-cloud-upload"
        size="small"
        label="Apply"
        :loading="committing"
        @click="apply"
      />
      <Button
        v-if="hasPrepared"
        severity="secondary"
        outlined
        icon="pi pi-times"
        size="small"
        label="Discard prepared"
        @click="abort"
      />
    </div>

    <Message v-if="info" severity="info" :closable="true" @close="info = null">
      {{ info }}
    </Message>
    <Message v-if="error" severity="error" :closable="true" @close="error = null">
      {{ error }}
    </Message>
    <Message v-if="rollingBack" severity="warn" :closable="false">
      Rolling back to selected revision…
    </Message>

    <section v-if="validationIssues.length > 0" class="webui-cfg__issues">
      <h2>Validation issues</h2>
      <ul>
        <li v-for="(it, idx) in validationIssues" :key="idx">
          <code>{{ it.path }}</code
          >: {{ it.message }}
        </li>
      </ul>
    </section>

    <section v-if="diff.length > 0" class="webui-cfg__diff">
      <h2>Diff ({{ diff.length }} ops)</h2>
      <ul>
        <li v-for="(op, idx) in diff" :key="idx">
          <!-- Map the JSON-patch-style op verbs to PrimeVue Tag
               severities. Anything we do not specifically know
               about falls back to `info` so a backend that adds
               a new op type does not render as an empty chip. -->
          <Tag
            class="webui-cfg__diff-tag"
            :value="op.op"
            :severity="
              op.op === 'added'
                ? 'success'
                : op.op === 'removed'
                  ? 'danger'
                  : op.op === 'changed'
                    ? 'warn'
                    : 'info'
            "
          />
          <code>{{ op.path }}</code>
          <span v-if="op.from !== undefined && op.from !== null">
            from <code>{{ op.from }}</code></span
          >
          <span v-if="op.to !== undefined && op.to !== null">
            to <code>{{ op.to }}</code></span
          >
        </li>
      </ul>
    </section>

    <DiffViewer
      :open="diffViewer.open"
      :title="diffViewer.title"
      :original-label="diffViewer.originalLabel"
      :modified-label="diffViewer.modifiedLabel"
      :original="diffViewer.original"
      :modified="diffViewer.modified"
      @close="diffViewer.open = false"
    />
    <DestructiveActionDialog
      :open="rollbackTarget != null"
      title="Rollback configuration"
      :description="
        'Creates a new commit carrying the YAML of revision #' +
        (rollbackTarget ?? '?') +
        ' and ' +
        'fans out config:reload on every peer. The cluster state will revert to ' +
        'that revision’s topology, credentials, roles, and runtime knobs. The ' +
        'rollback itself becomes the new latest revision; older commits stay in ' +
        'the timeline.'
      "
      :expected="String(rollbackTarget ?? '')"
      :prompt="`Type the revision number (${rollbackTarget ?? '?'}) to confirm:`"
      confirm-label="Rollback"
      :pending="rollingBack"
      @cancel="cancelRollback"
      @confirm="confirmRollback"
    />
    <DestructiveActionDialog
      :open="forceApplyTarget != null"
      title="Force apply revision"
      :description="
        'Rolls cluster YAML back to revision #' +
        (forceApplyTarget ?? '?') +
        ' AND ' +
        'fans out config:reload on every peer. Use this when a previous commit ' +
        'half-landed — the rollback creates a new commit carrying the target ' +
        'YAML, and the reload covers stragglers that missed the original.'
      "
      :expected="String(forceApplyTarget ?? '')"
      :prompt="`Type the revision number (${forceApplyTarget ?? '?'}) to confirm:`"
      confirm-label="Force apply"
      :pending="forceApplying"
      @cancel="cancelForceApply"
      @confirm="confirmForceApply"
    />
  </section>
</template>

<style scoped>
.webui-cfg {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
  /* The app shell (`<main class="webui-shell__main">`) is a column
     flexbox with `flex: 1`. Claiming `flex: 1` here makes the page
     consume the same height the shell already gives us, regardless
     of the top bar's actual height — no `100vh - <topbar>` math
     that breaks on different viewports / topbar paddings. */
  flex: 1;
  min-height: 0;
}
.webui-cfg__head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}
.webui-cfg__head h1 {
  margin: 0;
}
.webui-cfg__title-block {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}
.webui-cfg__title-meta {
  display: flex;
  gap: 0.4rem;
  flex-wrap: wrap;
}
.webui-cfg__buttons {
  display: flex;
  gap: 0.5rem;
}
.webui-cfg__split {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 320px;
  gap: 1rem;
  align-items: stretch;
  /* `flex: 1; min-height: 0` lets the split consume the rest of the
     column-flex parent so both grid items can fill it. */
  flex: 1;
  min-height: 0;
}
/* The editor wrapper expands to whatever the grid row gives it. The
   `min-height` keeps things usable on a half-screen window where
   `flex: 1` could otherwise collapse to zero. */
.webui-cfg__editor-slot {
  min-width: 0;
  min-height: 18rem;
}
/* The History panel sits in the second grid column. `align-items:
   stretch` on the grid already gives it the same row height as the
   editor column; the rules below remove HistoryPanel's own
   `max-height: 70vh` cap so it can actually use the room. The
   inner block keeps its `overflow-y: auto` so the timeline scrolls
   inside the panel instead of pushing the page taller.
   Vue forwards the `webui-cfg__history` class to HistoryPanel's
   root element, which already carries `webui-history` — so both
   classes land on the same `<aside>`. A descendant-style selector
   (`.webui-cfg__history :deep(.webui-history)`) would not match
   because the two are not in a parent/child relationship; styling
   directly on `.webui-cfg__history` is enough. */
.webui-cfg__history {
  align-self: stretch;
  min-height: 0;
  max-height: none;
  height: 100%;
  /* The HistoryPanel default `--webui-border` token is barely
     visible on the page background in the dark theme; once the
     card stretches to the bottom it stops looking like a card.
     Use the PrimeVue content border instead — it has the contrast
     operators expect from a panel boundary. */
  border-color: var(--p-content-border-color, var(--webui-border));
}
@media (max-width: 1100px) {
  .webui-cfg__split {
    grid-template-columns: 1fr;
  }
  /* On a stacked layout the History block does not have a fixed
     row height to inherit, so cap it explicitly to keep the page
     scroll length sane. */
  .webui-cfg__history {
    max-height: 50vh;
    height: auto;
  }
}
.webui-cfg__editor {
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}
.webui-cfg__actions {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}
.webui-cfg__issues,
.webui-cfg__diff {
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  padding: 0.75rem 1rem;
}
.webui-cfg__issues h2,
.webui-cfg__diff h2 {
  margin: 0 0 0.5rem;
  font-size: 1rem;
}
/* Tag inherits its severity colours from the PrimeVue theme; the
   only thing we add is consistent spacing between the chip and the
   path that follows it on every diff row. */
.webui-cfg__diff-tag {
  margin-right: 0.5rem;
}
</style>
