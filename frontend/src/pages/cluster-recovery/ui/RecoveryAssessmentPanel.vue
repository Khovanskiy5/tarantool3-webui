<script setup lang="ts">
/**
 * RC-5 — reusable risk-assessment panel.
 *
 * Renders the backend `recoveryPreflight` Assessment: a risk badge, the
 * ordered effects, a preconditions checklist (Ok/Cancel icons), a data-loss
 * banner, warnings, manual-recovery steps, copyable failure commands and a
 * docs link. For a `dangerous` action it also gates Apply behind an
 * acknowledge checkbox and a typed confirmation token; `safe`/`caution`
 * actions apply with a single click.
 */
import { computed } from 'vue';
import Tag from 'primevue/tag';
import Message from 'primevue/message';
import Button from 'primevue/button';
import Checkbox from 'primevue/checkbox';
import InputText from 'primevue/inputtext';

export interface RecoveryCheck {
  ok: boolean;
  label: string;
  detail?: string | null;
}
export interface RecoveryCommand {
  title: string;
  command: string;
  note?: string | null;
}
export interface RecoveryConfirm {
  required: boolean;
  token?: string | null;
  acknowledge?: string | null;
}
export interface Assessment {
  action: string;
  risk: 'safe' | 'caution' | 'dangerous' | string;
  dataLoss: boolean;
  autoSafe: boolean;
  summary: string;
  effects: string[];
  warnings: string[];
  manualRecovery: string[];
  preconditions: RecoveryCheck[];
  failureCommands: RecoveryCommand[];
  confirm: RecoveryConfirm;
  docs?: string | null;
  fingerprint: string;
}

const props = defineProps<{
  assessment: Assessment | null;
  busy?: boolean;
  acknowledge: boolean;
  token: string;
}>();

const emit = defineEmits<{
  (e: 'update:acknowledge', v: boolean): void;
  (e: 'update:token', v: string): void;
  (e: 'apply'): void;
  (e: 'cancel'): void;
}>();

const riskSeverity = computed(() => {
  switch (props.assessment?.risk) {
    case 'safe':
      return 'success';
    case 'caution':
      return 'warn';
    default:
      return 'danger';
  }
});

const needsConfirm = computed(() => props.assessment?.confirm.required === true);

const canApply = computed(() => {
  const a = props.assessment;
  if (!a || props.busy) return false;
  if (!needsConfirm.value) return true;
  return (
    props.acknowledge === true &&
    props.token.trim() === (a.confirm.token ?? '')
  );
});

function copyCommand(cmd: string) {
  if (navigator?.clipboard) {
    void navigator.clipboard.writeText(cmd);
  }
}
</script>

<template>
  <div v-if="assessment" class="assessment">
    <div class="assessment-head">
      <Tag :severity="riskSeverity" :value="assessment.risk.toUpperCase()" />
      <span class="summary">{{ assessment.summary }}</span>
    </div>

    <Message
      v-if="assessment.dataLoss"
      severity="error"
      variant="simple"
      size="small"
    >
      Data-loss risk: this action can lose committed data.
    </Message>

    <section v-if="assessment.effects.length" class="block">
      <h4>What will happen</h4>
      <ul>
        <li v-for="(e, i) in assessment.effects" :key="i">{{ e }}</li>
      </ul>
    </section>

    <section v-if="assessment.preconditions.length" class="block">
      <h4>Preconditions</h4>
      <ul class="checks">
        <li v-for="(c, i) in assessment.preconditions" :key="i">
          <i
            :class="c.ok ? 'pi pi-check-circle ok' : 'pi pi-times-circle bad'"
          />
          <span>{{ c.label }}</span>
          <small v-if="c.detail" class="detail"> — {{ c.detail }}</small>
        </li>
      </ul>
    </section>

    <Message
      v-for="(w, i) in assessment.warnings"
      :key="'w' + i"
      severity="warn"
      variant="simple"
      size="small"
    >
      {{ w }}
    </Message>

    <section v-if="assessment.manualRecovery.length" class="block">
      <h4>Preserve your data first</h4>
      <ul>
        <li v-for="(m, i) in assessment.manualRecovery" :key="i">{{ m }}</li>
      </ul>
    </section>

    <section v-if="assessment.failureCommands.length" class="block">
      <h4>If it fails</h4>
      <div
        v-for="(fc, i) in assessment.failureCommands"
        :key="i"
        class="cmd"
      >
        <div class="cmd-title">{{ fc.title }}</div>
        <div class="cmd-row">
          <code>{{ fc.command }}</code>
          <Button
            icon="pi pi-copy"
            size="small"
            text
            aria-label="Copy"
            @click="copyCommand(fc.command)"
          />
        </div>
        <small v-if="fc.note">{{ fc.note }}</small>
      </div>
    </section>

    <section v-if="needsConfirm" class="block confirm">
      <label class="ack">
        <Checkbox
          :model-value="acknowledge"
          binary
          @update:model-value="emit('update:acknowledge', $event)"
        />
        <span>{{ assessment.confirm.acknowledge }}</span>
      </label>
      <Message severity="warn" variant="simple" size="small">
        Type <code>{{ assessment.confirm.token }}</code> to confirm.
      </Message>
      <InputText
        :model-value="token"
        :placeholder="assessment.confirm.token ?? ''"
        @update:model-value="emit('update:token', $event ?? '')"
      />
    </section>

    <div class="actions">
      <a
        v-if="assessment.docs"
        class="docs"
        :href="'/docs/' + assessment.docs"
        target="_blank"
        rel="noopener"
      >
        <i class="pi pi-book" /> Runbook
      </a>
      <span class="spacer" />
      <Button label="Cancel" severity="secondary" text @click="emit('cancel')" />
      <Button
        :label="needsConfirm ? 'Apply (data loss)' : 'Apply'"
        :severity="needsConfirm ? 'danger' : 'primary'"
        :disabled="!canApply"
        :loading="busy"
        @click="emit('apply')"
      />
    </div>
  </div>
</template>

<style scoped>
.assessment {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.assessment-head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.summary {
  font-weight: 600;
}
.block h4 {
  margin: 0 0 0.25rem;
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.02em;
  opacity: 0.7;
}
.block ul {
  margin: 0;
  padding-left: 1.1rem;
}
.checks {
  list-style: none;
  padding-left: 0;
}
.checks li {
  display: flex;
  align-items: baseline;
  gap: 0.4rem;
}
.checks .ok {
  color: var(--p-green-500);
}
.checks .bad {
  color: var(--p-red-500);
}
.detail {
  opacity: 0.7;
}
.cmd {
  margin-bottom: 0.5rem;
}
.cmd-title {
  font-size: 0.85rem;
  opacity: 0.8;
}
.cmd-row {
  display: flex;
  align-items: center;
  gap: 0.4rem;
}
.cmd-row code {
  flex: 1;
  padding: 0.25rem 0.5rem;
  background: var(--p-content-background, rgba(0, 0, 0, 0.05));
  border-radius: 4px;
  overflow-x: auto;
}
.confirm .ack {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
.actions .spacer {
  flex: 1;
}
.docs {
  text-decoration: none;
  opacity: 0.85;
}
</style>
