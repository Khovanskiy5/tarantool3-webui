<script setup lang="ts">
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import SelectButton from 'primevue/selectbutton';
import Button from 'primevue/button';
import Tag from 'primevue/tag';

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
    <!-- Brand is a router-link to the cluster home, matching the
         "click the logo to go home" convention every operator
         already expects from admin consoles. -->
    <router-link to="/" class="webui-top-bar__left" :aria-label="t('app.title')">
      <strong class="webui-top-bar__brand">{{ t('app.title') }}</strong>
      <span class="webui-top-bar__subtitle">{{ t('app.subtitle') }}</span>
    </router-link>
    <div class="webui-top-bar__right">
      <IssuesBadge />
      <!-- Instance label + name expressed as a single PrimeVue Tag —
           same chip pattern the cluster / failover / issues pages use
           in their headers, so the visual language stays consistent
           across the whole shell. -->
      <Tag class="webui-top-bar__instance-tag" icon="pi pi-server" severity="secondary">
        <span class="webui-top-bar__instance-label">
          {{ t('widgets.top_bar.instance_label') }}
        </span>
        <span class="webui-top-bar__instance-name">{{ currentInstance }}</span>
      </Tag>
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
      <Tag
        v-if="session.user"
        icon="pi pi-user"
        severity="secondary"
        :value="session.user.user"
        :title="(session.user.roles ?? []).join(', ')"
      />
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
  /* The whole brand block is a router-link; strip the default link
     chrome so it reads as a heading until you hover it. */
  color: inherit;
  text-decoration: none;
}
.webui-top-bar__left:hover .webui-top-bar__brand {
  color: var(--p-primary-color, var(--webui-accent));
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

/* The instance Tag carries two pieces of text — an UPPERCASE label
   and the monospace instance name. Tag's default slot lets us style
   them separately while inheriting the chip's chrome (border /
   background / icon spacing) from the PrimeVue theme. */
.webui-top-bar__instance-tag {
  gap: 0.4rem;
}
.webui-top-bar__instance-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
.webui-top-bar__instance-name {
  font-weight: 600;
  font-family: var(--webui-font-mono);
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
