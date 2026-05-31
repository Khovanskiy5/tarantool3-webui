<script setup lang="ts">
// Initial bootstrap wizard (Task 36).
//
// Drives the operator from an empty cluster to a committed YAML.
//   1. /bootstrap loads — query bootstrapStatus + bootstrapTemplates
//   2. If `needed=false` show a banner and offer to navigate to /cluster
//   3. Otherwise: name + template select + preview YAML + Apply

import { computed, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import Message from 'primevue/message';
import Select from 'primevue/select';
import Card from 'primevue/card';

import { getClient } from '@/shared/api/graphql';
import { YamlEditor } from '@/widgets/yaml-editor';

interface BootstrapStatus {
  needed: boolean;
  reason: string | null;
  source: string | null;
  etcd_available: boolean | null;
  etcd_error: string | null;
}

interface TplMeta { name: string; title: string; description: string | null; }
interface InitResult {
  ok: boolean;
  yaml: string | null;
  revision: number | null;
  dry_run: boolean | null;
  etcd_used: boolean | null;
  etcd_error: string | null;
  error_code: string | null;
  message: string | null;
}

const router = useRouter();
const status = ref<BootstrapStatus | null>(null);
const templates = ref<TplMeta[]>([]);
const loading = ref(false);
const error = ref<string | null>(null);

const clusterName = ref('demo-cluster');
const selectedTpl = ref<string>('replicaset-3');
const renderedYaml = ref<string>('');
const renderError = ref<string | null>(null);
const applying = ref(false);
const applyInfo = ref<InitResult | null>(null);

const Q_BOOTSTRAP = /* GraphQL */ `
  query Bootstrap {
    bootstrapStatus { needed reason source etcd_available etcd_error }
    bootstrapTemplates { templates { name title description } }
  }
`;
const Q_RENDER = /* GraphQL */ `
  query Render($t: String!, $n: String) {
    bootstrapRender(template: $t, cluster_name: $n) { yaml error }
  }
`;
const M_INIT = /* GraphQL */ `
  mutation Init($t: String!, $n: String) {
    bootstrapInitialize(template: $t, cluster_name: $n) {
      ok yaml revision dry_run etcd_used etcd_error error_code message
    }
  }
`;

const load = async () => {
  loading.value = true; error.value = null;
  const res = await getClient().query<{
    bootstrapStatus: BootstrapStatus;
    bootstrapTemplates: { templates: TplMeta[] };
  }>(Q_BOOTSTRAP, {}).toPromise();
  loading.value = false;
  if (res.error) { error.value = res.error.message; return; }
  status.value = res.data?.bootstrapStatus ?? null;
  templates.value = res.data?.bootstrapTemplates?.templates ?? [];
  if (templates.value.length > 0
      && !templates.value.some(t => t.name === selectedTpl.value)) {
    selectedTpl.value = templates.value[0].name;
  }
};

const renderPreview = async () => {
  renderError.value = null;
  const res = await getClient().query<{ bootstrapRender: { yaml: string | null; error: string | null } }>(
    Q_RENDER, { t: selectedTpl.value, n: clusterName.value }
  ).toPromise();
  if (res.error) { renderError.value = res.error.message; return; }
  const r = res.data?.bootstrapRender;
  if (r?.error) { renderError.value = r.error; renderedYaml.value = ''; return; }
  renderedYaml.value = r?.yaml ?? '';
};

const apply = async () => {
  applying.value = true; error.value = null; applyInfo.value = null;
  const res = await getClient().mutation<{ bootstrapInitialize: InitResult }>(
    M_INIT, { t: selectedTpl.value, n: clusterName.value },
  ).toPromise();
  applying.value = false;
  if (res.error) { error.value = res.error.message; return; }
  applyInfo.value = res.data?.bootstrapInitialize ?? null;
  if (applyInfo.value?.ok) {
    setTimeout(() => router.push({ name: 'cluster' }), 2000);
  }
};

const templateOptions = computed(() =>
  templates.value.map(t => ({ value: t.name, label: t.title })));

const selectedTplMeta = computed(() =>
  templates.value.find(t => t.name === selectedTpl.value) ?? null);

watch([selectedTpl, clusterName], () => {
  if (status.value?.needed) void renderPreview();
});

onMounted(async () => {
  await load();
  if (status.value?.needed) await renderPreview();
});
</script>

<template>
  <section class="webui-bootstrap">
    <header><h1>Initial cluster bootstrap</h1></header>

    <Message v-if="error" severity="error" :closable="true" @close="error = null">{{ error }}</Message>

    <Message v-if="status && !status.needed" severity="info" :closable="false">
      Bootstrap is not required: <code>{{ status.reason }}</code>
      <div class="webui-bootstrap__actions">
        <Button label="Go to cluster" icon="pi pi-arrow-right" size="small"
          @click="router.push({ name: 'cluster' })" />
      </div>
    </Message>

    <template v-if="status?.needed">
      <Card class="webui-bootstrap__card">
        <template #title>Cluster identity</template>
        <template #content>
          <div class="webui-bootstrap__field">
            <label for="clusterName">Cluster name</label>
            <InputText id="clusterName" v-model="clusterName"
              placeholder="my-cluster" />
            <small>Letters, digits, dash, underscore, dot. Used in the YAML header.</small>
          </div>
        </template>
      </Card>

      <Card class="webui-bootstrap__card">
        <template #title>Template</template>
        <template #content>
          <Select v-model="selectedTpl" :options="templateOptions"
            option-label="label" option-value="value" />
          <p v-if="selectedTplMeta" class="webui-bootstrap__desc">
            {{ selectedTplMeta.description }}
          </p>
        </template>
      </Card>

      <Card class="webui-bootstrap__card">
        <template #title>Preview</template>
        <template #content>
          <Message v-if="renderError" severity="error" :closable="false">{{ renderError }}</Message>
          <YamlEditor v-model="renderedYaml" :readonly="true" height="40vh" />
        </template>
      </Card>

      <div class="webui-bootstrap__actions">
        <Button :loading="applying" :disabled="!renderedYaml || applying"
          icon="pi pi-check" label="Apply and bootstrap" severity="success"
          @click="apply" />
      </div>

      <Message v-if="applyInfo?.ok" severity="success" :closable="false">
        Bootstrap committed (revision {{ applyInfo.revision }},
        etcd: {{ applyInfo.etcd_used ? 'used' : applyInfo.dry_run ? 'dry-run' : 'unknown' }}).
        Redirecting to /cluster…
      </Message>
      <Message v-if="applyInfo && !applyInfo.ok" severity="error" :closable="false">
        Bootstrap failed: <code>{{ applyInfo.error_code }}</code> — {{ applyInfo.message }}
      </Message>
    </template>
  </section>
</template>

<style scoped>
.webui-bootstrap { padding: 1rem 1.5rem; display: flex; flex-direction: column; gap: 1rem; max-width: 980px; }
.webui-bootstrap header h1 { margin: 0; }
.webui-bootstrap__card { background: var(--webui-bg-elevated); }
.webui-bootstrap__field { display: flex; flex-direction: column; gap: 0.25rem; }
.webui-bootstrap__field small { color: var(--webui-text-muted); font-size: 0.78rem; }
.webui-bootstrap__desc { color: var(--webui-text-muted); margin: 0.5rem 0 0; font-size: 0.85rem; }
.webui-bootstrap__actions { display: flex; gap: 0.5rem; }
</style>
