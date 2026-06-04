<script setup lang="ts">
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';
import Button from 'primevue/button';
import Dialog from 'primevue/dialog';
import Message from 'primevue/message';

import { useSuggestionStore } from '@/entities/suggestion';
import {
  RecoveryAssessmentPanel,
  useRecoveryAssessment,
  type ActionResult,
} from '@/features/recovery-assessment';

const store = useSuggestionStore();
const { data, total } = storeToRefs(store);

const forceApply = computed(() => data.value?.forceApply ?? []);
const restartReplication = computed(() => data.value?.restartReplication ?? []);
const restartFailover = computed(() => data.value?.restartFailover ?? []);

// RC-6: the banner's actions now run through the SAME assessment model
// as the recovery-page wizards — read-only `recoveryPreflight` ->
// shared panel -> enforced `recoveryAction`. restart_replication is
// `safe`, force_apply is `caution`, rebootstrap is `dangerous` (gated
// behind acknowledge + typed token by the panel). No more bespoke
// `window.confirm` and no bypassing the risk model.
const lastResult = ref<ActionResult | null>(null);
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
    await store.refresh();
  },
});

const resultOk = computed(() => lastResult.value?.ok === true);
const resultText = computed(() => {
  const r = lastResult.value;
  if (!r) return '';
  if (r.error) return `${r.action}: ${r.error}`;
  const detail = r.results.map((x) => `${x.peer}: ${x.ok ? 'ok' : (x.msg ?? 'failed')}`).join('; ');
  return `${r.action}: ${r.ok ? 'ok' : 'failed'}${detail ? ` — ${detail}` : ''}`;
});

function runForceApply(uuid: string | null | undefined) {
  if (!uuid) return;
  void openAssessment('force_apply', JSON.stringify({ instanceUuids: [uuid] }));
}

function runRestartReplication(uuid: string | null | undefined) {
  if (!uuid) return;
  void openAssessment('restart_replication', JSON.stringify({ instanceUuids: [uuid] }));
}

function runRebootstrap(alias: string) {
  void openAssessment('rebootstrap', JSON.stringify({ alias }));
}

function runRestartFailover(alias: string) {
  void openAssessment('restart_failover', JSON.stringify({ aliases: [alias] }));
}
</script>

<template>
  <section v-if="total > 0" class="webui-suggestions-banner">
    <header class="webui-suggestions-banner__head">
      <i class="pi pi-bolt" aria-hidden="true" />
      <span>Suggested recovery actions ({{ total }})</span>
    </header>

    <ul v-if="forceApply.length > 0" class="webui-suggestions-banner__list">
      <li v-for="s in forceApply" :key="s.id">
        <strong>{{ s.instanceAlias }}</strong>
        <span class="webui-suggestions-banner__reason">{{ s.reason }}</span>
        <Button
          label="Reload config"
          icon="pi pi-sync"
          severity="secondary"
          size="small"
          :disabled="assessOpen"
          @click="runForceApply(s.instanceUuid)"
        />
      </li>
    </ul>

    <ul v-if="restartReplication.length > 0" class="webui-suggestions-banner__list">
      <li v-for="s in restartReplication" :key="s.id">
        <strong>{{ s.instanceAlias }}</strong>
        <span class="webui-suggestions-banner__reason">{{ s.reason }}</span>
        <Button
          label="Restart replication"
          icon="pi pi-replay"
          severity="secondary"
          size="small"
          :disabled="assessOpen"
          @click="runRestartReplication(s.instanceUuid)"
        />
        <!--
          Escalation for a split-brain follower that won't recover via
          box.cfg{replication=...}. `dangerous` — the shared panel gates
          it behind acknowledge + a typed token; the backend refuses if
          the target owns the synchronous queue.
        -->
        <Button
          label="Re-bootstrap"
          icon="pi pi-exclamation-triangle"
          severity="danger"
          size="small"
          :disabled="assessOpen"
          @click="runRebootstrap(s.instanceAlias)"
        />
      </li>
    </ul>

    <ul v-if="restartFailover.length > 0" class="webui-suggestions-banner__list">
      <li v-for="s in restartFailover" :key="s.id">
        <strong>{{ s.instanceAlias }}</strong>
        <span class="webui-suggestions-banner__reason">{{ s.reason }}</span>
        <Button
          label="Restart failover agent"
          icon="pi pi-replay"
          severity="secondary"
          size="small"
          :disabled="assessOpen"
          @click="runRestartFailover(s.instanceAlias)"
        />
      </li>
    </ul>

    <Message
      v-if="lastResult"
      :severity="resultOk ? 'success' : 'error'"
      variant="simple"
      size="small"
      :closable="false"
      class="webui-suggestions-banner__result"
    >
      {{ resultText }}
    </Message>

    <!-- Shared risk-assessment dialog (preflight -> panel -> enforced apply). -->
    <Dialog
      v-model:visible="assessOpen"
      modal
      header="Recovery — risk assessment"
      :style="{ width: '34rem' }"
    >
      <Message v-if="assessError" severity="error" :closable="false" class="mb-2">
        {{ assessError }}
      </Message>
      <div v-if="assessBusy && !assessment" class="webui-suggestions-banner__reason">
        Assessing…
      </div>
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
  </section>
</template>

<style scoped>
.webui-suggestions-banner {
  border: 1px solid var(--webui-border);
  border-left: 4px solid var(--webui-accent);
  border-radius: var(--webui-radius);
  background: rgba(78, 168, 222, 0.06);
  padding: 0.75rem 1rem;
  margin-bottom: 1rem;
}

.webui-suggestions-banner__head {
  display: flex;
  align-items: center;
  gap: 0.45rem;
  font-weight: 700;
  color: var(--webui-accent);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-size: 0.75rem;
  margin-bottom: 0.5rem;
}

.webui-suggestions-banner__list {
  list-style: none;
  padding: 0;
  margin: 0 0 0.5rem 0;
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}

.webui-suggestions-banner__list li {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  font-size: 0.85rem;
}

.webui-suggestions-banner__list li strong {
  font-family: var(--webui-font-mono);
}

.webui-suggestions-banner__reason {
  color: var(--webui-text-muted);
  font-size: 0.8rem;
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.webui-suggestions-banner__result {
  margin: 0.5rem 0 0;
  font-size: 0.8rem;
}
</style>
