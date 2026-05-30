<script setup lang="ts">
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import { setLocale, type Locale } from '@/shared/i18n';

const { t, locale } = useI18n();

const currentInstance = computed(() => {
  // Real instance name will come from the cluster entity store (Task 17).
  // For Task 4 the top-bar still renders correctly when nothing is set.
  return t('widgets.top_bar.no_instance');
});

const onLocaleChange = (event: Event) => {
  const value = (event.target as HTMLSelectElement).value as Locale;
  setLocale(value);
};
</script>

<template>
  <header class="webui-top-bar">
    <div class="webui-top-bar__left">
      <strong class="webui-top-bar__brand">{{ t('app.title') }}</strong>
      <span class="webui-top-bar__subtitle">{{ t('app.subtitle') }}</span>
    </div>
    <div class="webui-top-bar__right">
      <span class="webui-top-bar__instance">
        <span class="webui-top-bar__instance-label">
          {{ t('widgets.top_bar.instance_label') }}
        </span>
        <span class="webui-top-bar__instance-name">{{ currentInstance }}</span>
      </span>
      <label class="webui-top-bar__locale">
        <span class="webui-sr-only">{{ t('app.language') }}</span>
        <select
          :value="locale"
          aria-label="language"
          class="webui-top-bar__locale-select"
          @change="onLocaleChange"
        >
          <option value="ru">RU</option>
          <option value="en">EN</option>
        </select>
      </label>
    </div>
  </header>
</template>

<style scoped>
.webui-top-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.6rem 1rem;
  background: var(--webui-bg-elevated);
  border-bottom: 1px solid var(--webui-border);
}

.webui-top-bar__left {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
}

.webui-top-bar__brand {
  font-size: 1.05rem;
  letter-spacing: 0.02em;
}

.webui-top-bar__subtitle {
  color: var(--webui-text-muted);
  font-size: 0.85rem;
}

.webui-top-bar__right {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.webui-top-bar__instance {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  line-height: 1.2;
}

.webui-top-bar__instance-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  color: var(--webui-text-muted);
  letter-spacing: 0.06em;
}

.webui-top-bar__instance-name {
  font-weight: 600;
}

.webui-top-bar__locale-select {
  background: transparent;
  color: var(--webui-text);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  padding: 0.25rem 0.5rem;
  font: inherit;
}

.webui-sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
</style>
