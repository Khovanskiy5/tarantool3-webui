<script setup lang="ts">
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import { setLocale, type Locale } from '@/shared/i18n';
import { useHealth } from '@/shared/lib/health';

const { t, locale } = useI18n();
const { snapshot } = useHealth();

const currentInstance = computed(() => {
  // useHealth resolves asynchronously; until the first probe lands
  // (or if /api/health fails), fall back to the i18n placeholder.
  // After Task 17 lands the cluster entity store will own this
  // ref and TopBar will not call /api/health directly.
  const name = snapshot.value?.instance;
  return name && name.length > 0 ? name : t('widgets.top_bar.no_instance');
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
  gap: 0.75rem;
}

.webui-top-bar__instance {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0.65rem;
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  background: rgba(255, 255, 255, 0.02);
  line-height: 1.4;
  white-space: nowrap;
}

.webui-top-bar__instance-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  color: var(--webui-text-muted);
  letter-spacing: 0.06em;
}

.webui-top-bar__instance-name {
  font-weight: 600;
  font-family: var(--webui-font-mono);
}

.webui-top-bar__locale {
  display: inline-flex;
}

.webui-top-bar__locale-select {
  background: rgba(255, 255, 255, 0.02);
  color: var(--webui-text);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  /* Native arrow looks heavy against the dark theme; replace it with
     a small SVG chevron so the control reads as a custom dropdown
     while keeping native a11y semantics. */
  appearance: none;
  -webkit-appearance: none;
  -moz-appearance: none;
  padding: 0.3rem 1.6rem 0.3rem 0.65rem;
  font: inherit;
  font-weight: 600;
  letter-spacing: 0.03em;
  cursor: pointer;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 8' fill='none' stroke='%238b949e' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M1 1.5l5 5 5-5'/%3E%3C/svg%3E");
  background-repeat: no-repeat;
  background-position: right 0.55rem center;
  background-size: 0.7rem 0.5rem;
}

.webui-top-bar__locale-select:hover,
.webui-top-bar__locale-select:focus-visible {
  border-color: var(--webui-accent);
}

.webui-top-bar__locale-select option {
  background: var(--webui-bg-elevated);
  color: var(--webui-text);
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
