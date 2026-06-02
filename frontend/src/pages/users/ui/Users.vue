<script setup lang="ts">
import { onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';
import Message from 'primevue/message';

import { getClient } from '@/shared/api/graphql';

interface UserInfo {
  name: string;
  kind: string;
  roles_app: string[] | null;
}

const users = ref<UserInfo[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);

const Q = /* GraphQL */ `
  query Users {
    users {
      users {
        name
        kind
        roles_app
      }
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  const res = await getClient().query<{ users: { users: UserInfo[] } }>(Q, {}).toPromise();
  if (res.error) {
    error.value = res.error.message;
    loading.value = false;
    return;
  }
  users.value = res.data?.users?.users ?? [];
  loading.value = false;
};

const roleSeverity = (r: string) => {
  if (r === 'superuser') return 'danger';
  if (r === 'admin') return 'warn';
  if (r === 'operator') return 'info';
  return 'secondary';
};

onMounted(load);
</script>

<template>
  <section class="webui-users">
    <header class="webui-users__head">
      <h1>Users</h1>
      <Tag :value="`${users.length} users`" severity="secondary" />
    </header>
    <Message severity="info" :closable="false">
      User editing goes through the cluster config (<code>credentials.users.*</code>) via two-phase
      commit. The form will be wired once the multi-peer prepare/commit cycle is live.
    </Message>
    <Message v-if="error" severity="error" :closable="false">{{ error }}</Message>
    <DataTable :value="users" :loading="loading" data-key="name" size="small" striped-rows>
      <Column field="name" header="User" />
      <Column header="Type">
        <template #body="{ data }"><Tag :value="data.kind" severity="secondary" /></template>
      </Column>
      <Column header="WebUI roles">
        <template #body="{ data }">
          <span v-if="(data.roles_app ?? []).length === 0" class="webui-users__muted">—</span>
          <span v-else class="webui-users__roles">
            <Tag
              v-for="role in data.roles_app ?? []"
              :key="role"
              :value="role"
              :severity="roleSeverity(role)"
            />
          </span>
        </template>
      </Column>
    </DataTable>
  </section>
</template>

<style scoped>
.webui-users {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-users__head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  flex-wrap: wrap;
}
.webui-users__head h1 {
  margin: 0;
}
/* Wrap multiple role tags in a flex row so their spacing is owned
   by `gap` instead of a bespoke per-chip margin. */
.webui-users__roles {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.35rem;
}
.webui-users__muted {
  color: var(--p-text-muted-color, var(--webui-text-muted));
}
</style>
