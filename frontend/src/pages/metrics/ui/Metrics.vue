<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import Button from 'primevue/button';
import ToggleSwitch from 'primevue/toggleswitch';
import Message from 'primevue/message';

const text = ref('');
const error = ref<string | null>(null);
const loading = ref(false);
const live = ref(true);
let timer: number | null = null;

const load = async () => {
  loading.value = true;
  error.value = null;
  try {
    const res = await fetch('/api/metrics/webui', { credentials: 'same-origin' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    text.value = await res.text();
  } catch (e) {
    error.value = (e as Error).message;
  } finally {
    loading.value = false;
  }
};

const startTimer = () => {
  if (timer == null) timer = window.setInterval(load, 5000);
};
const stopTimer = () => {
  if (timer != null) {
    clearInterval(timer);
    timer = null;
  }
};

onMounted(() => {
  load();
  startTimer();
});
onBeforeUnmount(stopTimer);
</script>

<template>
  <section class="webui-metrics">
    <header class="webui-metrics__head">
      <h1>Metrics</h1>
      <div class="webui-metrics__controls">
        <Button
          size="small"
          icon="pi pi-refresh"
          label="Refresh"
          :loading="loading"
          @click="load"
        />
        <label class="webui-metrics__live">
          <ToggleSwitch
            v-model="live"
            @update:model-value="(v: boolean) => (v ? startTimer() : stopTimer())"
          />
          <span>Live (5s)</span>
        </label>
      </div>
    </header>
    <Message v-if="error" severity="error" variant="simple" size="small">{{ error }}</Message>
    <pre class="webui-metrics__body">{{ text }}</pre>
    <Message size="small" severity="secondary" variant="simple">
      Endpoint: <code>GET /api/metrics/webui</code>. App-level metrics from the Tarantool
      <code>metrics</code> rock live under <code>GET /api/metrics</code>.
    </Message>
  </section>
</template>

<style scoped>
.webui-metrics {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-metrics__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.webui-metrics__head h1 {
  margin: 0;
}
.webui-metrics__controls {
  display: flex;
  align-items: center;
  gap: 1rem;
}
.webui-metrics__live {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.85rem;
  color: var(--webui-text-muted);
}
.webui-metrics__body {
  font-family: var(--webui-font-mono);
  font-size: 0.8rem;
  padding: 1rem;
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  overflow: auto;
  white-space: pre;
  max-height: 60vh;
}
</style>
