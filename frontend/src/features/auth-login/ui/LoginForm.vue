<script setup lang="ts">
import { reactive, computed } from 'vue';
import { useRouter, useRoute } from 'vue-router';
import InputText from 'primevue/inputtext';
import Password from 'primevue/password';
import Button from 'primevue/button';
import Message from 'primevue/message';
import Fluid from 'primevue/fluid';

import { useLoginStore } from '../model/login';

const router = useRouter();
const route = useRoute();
const store = useLoginStore();

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
    <header class="webui-login-form__header">
      <h1>Sign in</h1>
      <p>Tarantool cluster administration</p>
    </header>

    <Fluid class="webui-login-form__body">
      <Message v-if="errorBanner" severity="error" :closable="false">
        {{ errorBanner }}
      </Message>

      <div class="r-field">
        <label for="login-user">Username</label>
        <InputText id="login-user" v-model="form.user" autocomplete="username" autofocus required />
      </div>

      <div class="r-field">
        <label for="login-password">Password</label>
        <!-- PrimeVue Password wraps a real <input>; `required` and
             `autocomplete` belong to the inner input, not the wrapper.
             `inputId` connects the outer <label for=...> to it so
             clicking the label focuses the field. Fluid handles the
             100% width — no `:deep(.p-password input)` hacks needed. -->
        <Password
          v-model="form.password"
          input-id="login-password"
          :feedback="false"
          toggle-mask
          :input-props="{ autocomplete: 'current-password', required: true }"
        />
      </div>

      <Button
        type="submit"
        :loading="store.pending"
        :disabled="!form.user || !form.password"
        label="Sign in"
      />
    </Fluid>
  </form>
</template>

<style scoped>
.webui-login-form {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  width: 320px;
  padding: 2rem;
  border: 1px solid var(--p-content-border-color, transparent);
  border-radius: 12px;
  background: var(--p-content-background, #fff);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35);
}
.webui-login-form__header {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.webui-login-form__header h1 {
  margin: 0;
  font-size: 1.4rem;
}
.webui-login-form__header p {
  margin: 0;
  color: var(--p-text-muted-color, #777);
  font-size: 0.85rem;
}
.webui-login-form__body {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.r-field {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  min-width: 0;
}
.r-field > label {
  font-size: 0.88rem;
  font-weight: 600;
}
</style>
