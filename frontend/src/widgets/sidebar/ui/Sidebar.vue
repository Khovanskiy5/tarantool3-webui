<script setup lang="ts">
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';

interface SidebarItem {
  key: string;
  to: string;
  iconClass: string;
  labelKey: string;
}

const { t } = useI18n();
const route = useRoute();

// Items live in the widget for now; once feature/slice ownership is
// firmed up (Tasks 22+) the registry will move into entity stores so
// individual pages can gate their menu entries via RBAC.
const items: SidebarItem[] = [
  { key: 'cluster',       to: '/cluster',       iconClass: 'pi pi-share-alt',   labelKey: 'widgets.sidebar.cluster' },
  { key: 'issues',        to: '/issues',        iconClass: 'pi pi-exclamation-triangle', labelKey: 'widgets.sidebar.issues' },
  { key: 'config-editor', to: '/config-editor', iconClass: 'pi pi-code',        labelKey: 'widgets.sidebar.config_editor' },
  { key: 'data-explorer', to: '/data-explorer', iconClass: 'pi pi-table',       labelKey: 'widgets.sidebar.data_explorer' },
  { key: 'sql',           to: '/sql',           iconClass: 'pi pi-bolt',        labelKey: 'widgets.sidebar.sql' },
  { key: 'users',         to: '/users',         iconClass: 'pi pi-users',       labelKey: 'widgets.sidebar.users' },
  { key: 'failover',      to: '/failover',      iconClass: 'pi pi-sync',        labelKey: 'widgets.sidebar.failover' },
  { key: 'cluster-recovery', to: '/cluster-recovery', iconClass: 'pi pi-shield', labelKey: 'widgets.sidebar.cluster_recovery' },
  { key: 'vshard',        to: '/vshard',        iconClass: 'pi pi-th-large',    labelKey: 'widgets.sidebar.vshard' },
  { key: 'metrics',       to: '/metrics',       iconClass: 'pi pi-chart-line',  labelKey: 'widgets.sidebar.metrics' },
  { key: 'snapshots',     to: '/snapshots',     iconClass: 'pi pi-database',    labelKey: 'widgets.sidebar.snapshots' },
  { key: 'console',       to: '/console',       iconClass: 'pi pi-microchip',   labelKey: 'widgets.sidebar.console' },
  { key: 'audit',         to: '/audit',         iconClass: 'pi pi-list',        labelKey: 'widgets.sidebar.audit' },
];

const currentKey = computed(() => {
  const segment = route.path.split('/').filter(Boolean)[0] ?? '';
  return segment;
});
</script>

<template>
  <nav class="webui-sidebar" aria-label="primary">
    <ul class="webui-sidebar__list">
      <li
        v-for="item in items"
        :key="item.key"
        class="webui-sidebar__item"
      >
        <router-link
          :to="item.to"
          class="webui-sidebar__link"
          :aria-current="currentKey === item.key ? 'page' : undefined"
        >
          <i :class="item.iconClass" aria-hidden="true" />
          <span>{{ t(item.labelKey) }}</span>
        </router-link>
      </li>
    </ul>
  </nav>
</template>

<style scoped>
.webui-sidebar {
  width: 220px;
  background: var(--webui-bg-elevated);
  border-right: 1px solid var(--webui-border);
  flex-shrink: 0;
  padding: 1rem 0;
}

.webui-sidebar__list {
  list-style: none;
  margin: 0;
  padding: 0;
}

.webui-sidebar__item {
  margin: 0;
}

.webui-sidebar__link {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.5rem 1rem;
  color: var(--webui-text);
  font-size: 0.9rem;
}

.webui-sidebar__link[aria-current='page'] {
  background: rgba(78, 168, 222, 0.12);
  border-left: 3px solid var(--webui-accent);
  padding-left: calc(1rem - 3px);
  font-weight: 600;
}

.webui-sidebar__link:hover {
  background: rgba(255, 255, 255, 0.04);
  text-decoration: none;
}
</style>
