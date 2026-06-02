<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import DataTable from 'primevue/datatable';
import Column from 'primevue/column';
import Tag from 'primevue/tag';
import Button from 'primevue/button';
import Message from 'primevue/message';
import Dropdown from 'primevue/dropdown';

import { getClient } from '@/shared/api/graphql';

interface VshardGroup {
  name: string;
  total_buckets: number | null;
  distribution: string | null;
  rebalancer: string | null;
  status: string;
}

interface CanBootstrap {
  ok: boolean;
  group: string;
  reasons: string[] | null;
}
interface BootstrapResult {
  ok: boolean;
  group: string;
  router: string | null;
  latency_ms: number | null;
  message: string | null;
}

const groups = ref<VshardGroup[]>([]);
const knownGroups = ref<string[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);

const selectedGroup = ref<string>('default');
const canBoot = ref<CanBootstrap | null>(null);
const bootstrapping = ref(false);
const bootInfo = ref<string | null>(null);

const VSHARD_Q = /* GraphQL */ `
  query Vshard($group: String!) {
    vshard {
      groups {
        name
        total_buckets
        distribution
        rebalancer
        status
      }
    }
    vshardKnownGroups {
      groups
    }
    canBootstrapVshard(group: $group) {
      ok
      group
      reasons
    }
  }
`;

const BOOTSTRAP_M = /* GraphQL */ `
  mutation BootstrapVshard($group: String!) {
    bootstrapVshard(group: $group) {
      ok
      group
      router
      latency_ms
      message
    }
  }
`;

const load = async () => {
  loading.value = true;
  error.value = null;
  bootInfo.value = null;
  const res = await getClient()
    .query<{
      vshard: { groups: VshardGroup[] };
      vshardKnownGroups: { groups: string[] };
      canBootstrapVshard: CanBootstrap;
    }>(VSHARD_Q, { group: selectedGroup.value })
    .toPromise();
  if (res.error) {
    error.value = res.error.message;
    loading.value = false;
    return;
  }
  groups.value = res.data?.vshard?.groups ?? [];
  knownGroups.value = res.data?.vshardKnownGroups?.groups ?? [];
  canBoot.value = res.data?.canBootstrapVshard ?? null;
  loading.value = false;
};

const bootstrap = async () => {
  bootstrapping.value = true;
  bootInfo.value = null;
  error.value = null;
  const res = await getClient()
    .mutation<{ bootstrapVshard: BootstrapResult }>(BOOTSTRAP_M, { group: selectedGroup.value })
    .toPromise();
  bootstrapping.value = false;
  if (res.error) {
    error.value = res.error.message;
    return;
  }
  const r = res.data?.bootstrapVshard;
  if (r?.ok) {
    bootInfo.value = `Bootstrap ok on router ${r.router} (${(r.latency_ms ?? 0).toFixed(1)} ms).`;
    await load();
  } else {
    error.value = r?.message ?? 'bootstrap failed';
  }
};

const groupOptions = computed(() => {
  const seen = new Set<string>(knownGroups.value);
  if (selectedGroup.value && !seen.has(selectedGroup.value)) seen.add(selectedGroup.value);
  return Array.from(seen);
});

onMounted(load);
</script>

<template>
  <section class="webui-vshard">
    <h1>Vshard</h1>

    <Message v-if="!loading && knownGroups.length === 0" severity="info" :closable="false">
      No vshard groups configured. Enable sharding in cluster config to populate this view.
    </Message>

    <p v-if="error" class="webui-vshard__error">{{ error }}</p>
    <Message v-if="bootInfo" severity="success" :closable="true" @close="bootInfo = null">
      {{ bootInfo }}
    </Message>

    <DataTable
      v-if="groups.length > 0"
      :value="groups"
      :loading="loading"
      data-key="name"
      size="small"
      striped-rows
    >
      <Column field="name" header="Group" />
      <Column field="total_buckets" header="Buckets" />
      <Column header="Distribution">
        <template #body="{ data }">{{ data.distribution ?? '—' }}</template>
      </Column>
      <Column header="Rebalancer">
        <template #body="{ data }">{{ data.rebalancer ?? '—' }}</template>
      </Column>
      <Column header="Status">
        <template #body="{ data }">
          <Tag :value="data.status" :severity="data.status === 'unknown' ? 'warn' : 'info'" />
        </template>
      </Column>
    </DataTable>

    <section v-if="knownGroups.length > 0" class="webui-vshard__bootstrap">
      <header class="webui-vshard__bootstrap-head">
        <h2>Bootstrap</h2>
        <Dropdown
          v-model="selectedGroup"
          :options="groupOptions"
          placeholder="Select group"
          size="small"
          @update:model-value="load"
        />
      </header>
      <Message v-if="canBoot && !canBoot.ok" severity="warn" :closable="false">
        Preconditions failed for <code>{{ canBoot.group }}</code
        >:
        <ul>
          <li v-for="r in canBoot.reasons ?? []" :key="r">{{ r }}</li>
        </ul>
      </Message>
      <Button
        icon="pi pi-bolt"
        size="small"
        label="Bootstrap vshard"
        :disabled="!canBoot?.ok || bootstrapping"
        :loading="bootstrapping"
        @click="bootstrap"
      />
    </section>
  </section>
</template>

<style scoped>
.webui-vshard {
  padding: 1rem 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.webui-vshard h1 {
  margin: 0;
}
.webui-vshard h2 {
  margin: 0;
  font-size: 1.05rem;
}
.webui-vshard__error {
  color: var(--p-message-error-color, #d83535);
}
.webui-vshard__bootstrap {
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  border-radius: var(--webui-radius);
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.webui-vshard__bootstrap-head {
  display: flex;
  align-items: center;
  gap: 1rem;
}
</style>
