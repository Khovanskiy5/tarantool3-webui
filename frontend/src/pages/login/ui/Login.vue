<script setup lang="ts">
import { LoginForm } from '@/features/auth-login';
</script>

<template>
  <main class="webui-login-page">
    <LoginForm />
  </main>
</template>

<style scoped>
.webui-login-page {
  min-height: 100vh;
  display: grid;
  place-items: center;
  background: var(--webui-bg, #f4f5f7);
}
</style>
