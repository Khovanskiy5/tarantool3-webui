<script setup lang="ts">
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';

const { t } = useI18n();
const router = useRouter();

const goHome = () => router.push('/');
</script>

<template>
  <section class="webui-error-page" role="alert" aria-live="polite">
    <div class="webui-error-page__status">403</div>
    <h1 class="webui-error-page__title">{{ t('pages.forbidden.title') }}</h1>
    <p class="webui-error-page__description">
      {{ t('pages.forbidden.description') }}
    </p>
    <button
      type="button"
      class="webui-error-page__action"
      @click="goHome"
    >
      {{ t('common.back_to_dashboard') }}
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
  font-weight: 700;
  color: var(--webui-warning);
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

.webui-error-page__action:hover {
  filter: brightness(1.1);
}
</style>
