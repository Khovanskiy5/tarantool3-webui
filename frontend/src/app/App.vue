<script setup lang="ts">
import { Sidebar } from '@/widgets/sidebar';
import { TopBar } from '@/widgets/top-bar';
</script>

<template>
  <div class="webui-shell">
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
</template>

<style scoped>
.webui-shell {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
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
