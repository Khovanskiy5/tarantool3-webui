<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import { withTag } from '@/shared/lib/log';

const { t } = useI18n();
const logger = withTag('network-error-page');

const reconnecting = ref(false);
const attemptCount = ref(0);

const retry = () => {
  reconnecting.value = true;
  attemptCount.value += 1;
  logger.info('manual reconnect attempt', { attempt: attemptCount.value });
  // The actual reconnect is owned by `@/shared/api/ws` and the urql
  // client; reloading the page is the safest user-triggered recovery
  // until those modules expose imperative APIs.
  window.location.reload();
};

onBeforeUnmount(() => {
  reconnecting.value = false;
});
</script>

<template>
  <section class="webui-error-page" role="alert" aria-live="polite">
    <div class="webui-error-page__status" aria-hidden="true">⚠</div>
    <h1 class="webui-error-page__title">{{ t('pages.network_error.title') }}</h1>
    <p class="webui-error-page__description">
      {{ t('pages.network_error.description') }}
    </p>
    <button
      type="button"
      class="webui-error-page__action"
      :disabled="reconnecting"
      @click="retry"
    >
      <span v-if="reconnecting">{{ t('pages.network_error.reconnecting') }}</span>
      <span v-else>{{ t('common.retry') }}</span>
    </button>
  </section>
</template>

<style scoped>
.webui-error-page {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 4rem 1rem;
  text-align: center;
  flex: 1;
}

.webui-error-page__status {
  font-size: 4rem;
  color: var(--webui-danger);
}

.webui-error-page__title {
  margin: 1rem 0 0.5rem 0;
  font-size: 1.5rem;
}

.webui-error-page__description {
  max-width: 32rem;
  color: var(--webui-text-muted);
  margin-bottom: 2rem;
}

.webui-error-page__action {
  background: var(--webui-accent);
  color: var(--webui-bg);
  border: none;
  border-radius: var(--webui-radius);
  padding: 0.5rem 1.25rem;
  font-weight: 600;
  cursor: pointer;
}

.webui-error-page__action:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.webui-error-page__action:not(:disabled):hover {
  filter: brightness(1.1);
}
</style>
