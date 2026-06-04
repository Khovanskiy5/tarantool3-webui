<script setup lang="ts">
import { useRoute } from 'vue-router';
import { computed } from 'vue';

import Toast from 'primevue/toast';

import { Sidebar } from '@/widgets/sidebar';
import { TopBar } from '@/widgets/top-bar';

const route = useRoute();
// The login (and any future setup-style) page renders full-bleed
// without the shared TopBar/Sidebar shell.
const hideShell = computed(() => route.meta?.hideShell === true);
</script>

<template>
  <div v-if="hideShell" class="webui-shell webui-shell--bare">
    <router-view v-slot="{ Component }">
      <Suspense>
        <component :is="Component" />
        <template #fallback>
          <div class="webui-shell__loading" role="status">Loading…</div>
        </template>
      </Suspense>
    </router-view>
  </div>
  <div v-else class="webui-shell">
    <TopBar />
    <div class="webui-shell__body">
      <Sidebar />
      <main class="webui-shell__main" tabindex="-1">
        <router-view v-slot="{ Component }">
          <Suspense>
            <component :is="Component" />
            <template #fallback>
              <div class="webui-shell__loading" role="status">Loading…</div>
            </template>
          </Suspense>
        </router-view>
      </main>
    </div>
  </div>
  <Toast position="bottom-right" />
</template>

<style scoped>
.webui-shell {
  display: flex;
  flex-direction: column;
  /* Cap the shell at the viewport so `.webui-shell__main`'s
     `overflow: auto` actually engages instead of growing the
     whole page. Pages with naturally tall content scroll inside
     `main`; pages that wire up their own per-section scroll
     (config-editor, logs, console) keep the outer surface
     pinned and let the inner panels handle the scroll. */
  height: 100vh;
  background: var(--webui-bg);
}
.webui-shell--bare {
  background: var(--webui-bg);
}

.webui-shell__body {
  display: flex;
  flex: 1;
  min-height: 0;
}

.webui-shell__main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  overflow: auto;
}

.webui-shell__loading {
  padding: 2rem;
  color: var(--webui-text-muted);
  text-align: center;
}
</style>
