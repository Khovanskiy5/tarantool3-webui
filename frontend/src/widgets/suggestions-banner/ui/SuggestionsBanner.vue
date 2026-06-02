<script setup lang="ts">
import { storeToRefs } from 'pinia';
import { computed, ref } from 'vue';

import { useSuggestionStore } from '@/entities/suggestion';
import { withTag } from '@/shared/lib/log';

const log = withTag('suggestions-banner');
const store = useSuggestionStore();
const { data, total } = storeToRefs(store);

const forceApply = computed(() => data.value?.forceApply ?? []);
const restartReplication = computed(() => data.value?.restartReplication ?? []);

const lastAction = ref<{
  type: 'force_apply' | 'restart_replication' | 'rebootstrap';
  ok: boolean;
  message: string;
  // Set after a failed restart_replication so the banner can offer
  // the destructive follow-up ("Re-bootstrap this instance") next
  // to the message instead of forcing the operator to remember the
  // recovery procedure.
  rebootstrap_for_alias?: string | null;
} | null>(null);
const busy = ref(false);

const restartReplicationFailed = computed(
  () =>
    lastAction.value?.type === 'restart_replication' &&
    !lastAction.value.ok &&
    Boolean(lastAction.value.rebootstrap_for_alias),
);

async function runForceApply(uuid: string | null | undefined) {
  if (!uuid || busy.value) return;
  busy.value = true;
  try {
    const res = await store.applyForceApply([uuid]);
    if (res) {
      lastAction.value = {
        type: 'force_apply',
        ok: res.ok,
        message: res.message ?? `dispatched to ${res.results.length} peer(s)`,
      };
    }
  } catch (err) {
    log.error('apply force_apply failed', { err: String(err) });
  } finally {
    busy.value = false;
  }
}

async function runRestartReplication(uuid: string | null | undefined, alias: string) {
  if (!uuid || busy.value) return;
  busy.value = true;
  try {
    const res = await store.applyRestartReplication([uuid]);
    if (res) {
      // When `ok: false` comes back the backend already crafted a
      // human message that says STILL STOPPED — usually split-brain
      // that can't be recovered by `box.cfg{replication=...}` alone.
      // Stash the alias so the banner can offer the destructive
      // re-bootstrap follow-up button.
      lastAction.value = {
        type: 'restart_replication',
        ok: res.ok,
        message: res.message ?? `dispatched to ${res.results.length} peer(s)`,
        rebootstrap_for_alias: res.ok ? null : alias,
      };
    }
  } catch (err) {
    log.error('apply restart_replication failed', { err: String(err) });
  } finally {
    busy.value = false;
  }
}

async function runRebootstrap(alias: string) {
  if (busy.value) return;
  const confirmed = window.confirm(
    `Re-bootstrap instance "${alias}"?\n\n` +
      'This wipes WAL/snap on the target and triggers Docker restart-policy.\n' +
      'Replication will catch up fresh from healthy peers (~10–30s downtime\n' +
      'for this instance). Refused if the target owns the synchronous queue\n' +
      '(promote another peer first).',
  );
  if (!confirmed) return;
  busy.value = true;
  try {
    const res = await store.rebootstrapInstance(alias);
    lastAction.value = {
      type: 'rebootstrap',
      ok: res.ok,
      message: res.message ?? '(no message)',
    };
  } catch (err) {
    log.error('rebootstrap dispatch failed', { err: String(err) });
  } finally {
    busy.value = false;
  }
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
        <button
          type="button"
          class="webui-suggestions-banner__action"
          :disabled="busy"
          @click="runForceApply(s.instanceUuid)"
        >
          Reload config
        </button>
      </li>
    </ul>

    <ul v-if="restartReplication.length > 0" class="webui-suggestions-banner__list">
      <li v-for="s in restartReplication" :key="s.id">
        <strong>{{ s.instanceAlias }}</strong>
        <span class="webui-suggestions-banner__reason">{{ s.reason }}</span>
        <button
          type="button"
          class="webui-suggestions-banner__action"
          :disabled="busy"
          @click="runRestartReplication(s.instanceUuid, s.instanceAlias)"
        >
          Restart replication
        </button>
      </li>
    </ul>

    <p
      v-if="lastAction"
      :class="[
        'webui-suggestions-banner__result',
        lastAction.ok
          ? 'webui-suggestions-banner__result--ok'
          : 'webui-suggestions-banner__result--err',
      ]"
    >
      {{ lastAction.type }}: {{ lastAction.message }}
    </p>

    <!--
      Restart replication recovered nothing (typical split-brain
      symptom). Offer the destructive recovery — re-bootstrap the
      affected instance to clean state, then replication catches up
      from healthy peers. The button is guarded by a native confirm()
      and a backend-side refusal on the queue owner.
    -->
    <p v-if="restartReplicationFailed" class="webui-suggestions-banner__followup">
      <strong>Replication did not recover.</strong>
      Likely split-brain (LSN divergence in the synchronous queue). Manual recovery:
      <button
        type="button"
        class="webui-suggestions-banner__action webui-suggestions-banner__action--danger"
        :disabled="busy"
        @click="runRebootstrap(lastAction!.rebootstrap_for_alias!)"
      >
        Re-bootstrap {{ lastAction!.rebootstrap_for_alias }}
      </button>
    </p>
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

.webui-suggestions-banner__action {
  background: var(--webui-accent);
  color: var(--webui-bg);
  border: none;
  border-radius: var(--webui-radius);
  padding: 0.25rem 0.7rem;
  font-weight: 600;
  cursor: pointer;
  font: inherit;
  font-size: 0.8rem;
  font-weight: 700;
}

.webui-suggestions-banner__action:disabled {
  opacity: 0.6;
  cursor: progress;
}

.webui-suggestions-banner__result {
  margin: 0.5rem 0 0;
  font-size: 0.8rem;
}

.webui-suggestions-banner__result--ok {
  color: var(--webui-success);
}
.webui-suggestions-banner__result--err {
  color: var(--webui-danger);
}

.webui-suggestions-banner__followup {
  margin: 0.5rem 0 0;
  padding: 0.5rem 0.75rem;
  font-size: 0.8rem;
  border-radius: var(--webui-radius);
  background: rgba(220, 80, 80, 0.08);
  border: 1px solid rgba(220, 80, 80, 0.35);
  color: var(--webui-text-muted);
  display: flex;
  align-items: center;
  gap: 0.6rem;
  flex-wrap: wrap;
}
.webui-suggestions-banner__action--danger {
  background: var(--webui-danger, #c0392b);
  color: #fff;
}
</style>
