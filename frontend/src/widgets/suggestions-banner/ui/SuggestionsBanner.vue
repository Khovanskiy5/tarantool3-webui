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
  type: 'force_apply' | 'restart_replication';
  ok: boolean;
  message: string;
} | null>(null);
const busy = ref(false);

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

async function runRestartReplication(uuid: string | null | undefined) {
  if (!uuid || busy.value) return;
  busy.value = true;
  try {
    const res = await store.applyRestartReplication([uuid]);
    if (res) {
      lastAction.value = {
        type: 'restart_replication',
        ok: res.ok,
        message: res.message ?? `dispatched to ${res.results.length} peer(s)`,
      };
    }
  } catch (err) {
    log.error('apply restart_replication failed', { err: String(err) });
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
          @click="runRestartReplication(s.instanceUuid)"
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

.webui-suggestions-banner__result--ok  { color: var(--webui-success); }
.webui-suggestions-banner__result--err { color: var(--webui-danger);  }
</style>
