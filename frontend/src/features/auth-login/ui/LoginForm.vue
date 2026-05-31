<script setup lang="ts">
import { reactive, computed } from 'vue';
import { useRouter, useRoute } from 'vue-router';
import InputText from 'primevue/inputtext';
import Password from 'primevue/password';
import Button from 'primevue/button';
import Message from 'primevue/message';

import { useLoginStore } from '../model/login';

const router = useRouter();
const route  = useRoute();
const store  = useLoginStore();

const form = reactive({ user: '', password: '' });

const errorBanner = computed(() => {
  if (!store.error) return null;
  switch (store.error.code) {
    case 'LOGIN_FAILED':
      return 'Invalid username or password.';
    case 'FORBIDDEN':
      return 'This account is not allowed to sign in.';
    case 'RATE_LIMITED':
      return 'Too many failed attempts. Try again in a minute.';
    case 'UNAVAILABLE':
      return 'Session storage is unavailable — try a different instance.';
    case 'INVALID_QUERY':
      return 'Username and password are required.';
    default:
      return store.error.message || 'Network error.';
  }
});

const submit = async () => {
  const ok = await store.submit({
    user: form.user.trim(),
    password: form.password,
  });
  if (!ok) return;
  const next = typeof route.query.next === 'string' ? route.query.next : '/cluster';
  router.push(next);
};
</script>

<template>
  <form class="webui-login-form" @submit.prevent="submit">
    <h1 class="webui-login-form__title">Sign in</h1>
    <p class="webui-login-form__subtitle">Tarantool cluster administration</p>

    <Message v-if="errorBanner" severity="error" :closable="false">
      {{ errorBanner }}
    </Message>

    <label class="webui-login-form__field">
      <span class="webui-login-form__label">Username</span>
      <InputText
        v-model="form.user"
        autocomplete="username"
        autofocus
        required
      />
    </label>

    <label class="webui-login-form__field">
      <span class="webui-login-form__label">Password</span>
      <Password
        v-model="form.password"
        :feedback="false"
        toggle-mask
        autocomplete="current-password"
        required
      />
    </label>

    <Button
      type="submit"
      class="webui-login-form__submit"
      :loading="store.pending"
      :disabled="!form.user || !form.password"
      label="Sign in"
    />
  </form>
</template>

<style scoped>
.webui-login-form {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  width: 320px;
  padding: 2rem;
  border: 1px solid var(--p-content-border-color, transparent);
  border-radius: 12px;
  background: var(--p-content-background, #fff);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35);
}
.webui-login-form__title {
  margin: 0;
  font-size: 1.4rem;
}
.webui-login-form__subtitle {
  margin: 0 0 0.5rem;
  color: var(--p-text-muted-color, #777);
  font-size: 0.85rem;
}
.webui-login-form__field {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.webui-login-form__label {
  font-size: 0.85rem;
  color: var(--p-text-muted-color, #777);
}
.webui-login-form__submit {
  margin-top: 0.5rem;
}

/* PrimeVue Password puts input + toggle-icon side-by-side in a flex
 * wrapper, so the input ends short of the wrapper edge and the icon
 * sits on a strip of bare wrapper background. Stretch the input to
 * fill the wrapper and add right-padding so the icon overlays inside. */
.webui-login-form :deep(.p-password) {
  display: block;
  width: 100%;
}
.webui-login-form :deep(.p-password input) {
  width: 100%;
  padding-inline-end: 2.25rem;
}
.webui-login-form :deep(.p-password-toggle-mask-icon) {
  right: 0.75rem;
  color: var(--p-text-muted-color, #888);
  cursor: pointer;
}
.webui-login-form :deep(input.p-inputtext) {
  width: 100%;
}
</style>
