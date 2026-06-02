<script setup lang="ts">
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import SelectButton from 'primevue/selectbutton';
import Button from 'primevue/button';

import { SUPPORTED_LOCALES, setLocale, type Locale } from '@/shared/i18n';
import { useHealth } from '@/shared/lib/health';
import { IssuesBadge } from '@/widgets/issues-badge';
import { useSessionStore } from '@/entities/session';
import { performLogout } from '@/features/auth-logout';

const router = useRouter();
const session = useSessionStore();

const onLogout = async () => {
  await performLogout();
  router.push({ name: 'login' });
};

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

// SelectButton stays a segmented switch as long as the locale set is
// small (≤ 4 entries fit comfortably). The day a fifth locale lands,
// swap to PrimeVue's `Select`; the v-model contract is identical.
const localeOptions = computed(() =>
  SUPPORTED_LOCALES.map((code) => ({
    value: code,
    label: code.toUpperCase(),
  })),
);

const localeModel = computed<Locale>({
  get: () => locale.value as Locale,
  set: (value) => {
    if (value && value !== locale.value) setLocale(value);
  },
});
</script>

<template>
  <header class="webui-top-bar">
    <div class="webui-top-bar__left">
      <strong class="webui-top-bar__brand">{{ t('app.title') }}</strong>
      <span class="webui-top-bar__subtitle">{{ t('app.subtitle') }}</span>
    </div>
    <div class="webui-top-bar__right">
      <IssuesBadge />
      <span class="webui-top-bar__instance">
        <span class="webui-top-bar__instance-label">
          {{ t('widgets.top_bar.instance_label') }}
        </span>
        <span class="webui-top-bar__instance-name">{{ currentInstance }}</span>
      </span>
      <!-- `allowEmpty="false"` is critical: SelectButton's default
           lets the user click the active option to deselect, which
           would leave the SPA with no locale. -->
      <SelectButton
        v-model="localeModel"
        :options="localeOptions"
        option-label="label"
        option-value="value"
        :allow-empty="false"
        :aria-label="t('app.language')"
        size="small"
        class="webui-top-bar__locale-switch"
      />
      <span
        v-if="session.user"
        class="webui-top-bar__user"
        :title="(session.user.roles ?? []).join(', ')"
      >
        <i class="pi pi-user" /> {{ session.user.user }}
      </span>
      <Button
        v-if="session.user"
        text
        rounded
        size="small"
        aria-label="Sign out"
        icon="pi pi-sign-out"
        @click="onLogout"
      />
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

.webui-top-bar__user {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.25rem 0.5rem;
  border-radius: var(--webui-radius);
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid var(--webui-border);
  font-family: var(--webui-font-mono);
  font-size: 0.85rem;
}

/* PrimeVue 4 / Aura paints SelectButton via the design-token system,
   so most styling is inherited. The :deep selectors below only adjust
   labels: the locale codes look stronger in our brand monospace and
   slightly tighter than Aura's default. */
.webui-top-bar__locale-switch :deep(.p-togglebutton),
.webui-top-bar__locale-switch :deep(.p-button) {
  font-family: var(--webui-font-mono);
  font-weight: 600;
  letter-spacing: 0.04em;
  padding: 0.3rem 0.6rem;
  min-width: 2.5rem;
}
</style>
