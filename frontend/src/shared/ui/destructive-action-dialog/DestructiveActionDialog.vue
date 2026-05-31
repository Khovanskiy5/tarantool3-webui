<script setup lang="ts">
/**
 * Type-to-confirm destructive action dialog (Phase 5 Task 5.16).
 *
 * Operator types the expected token (instance alias, replicaset
 * name, or a fixed phrase like "I ACCEPT DATA LOSS") before the
 * Confirm button enables. The typed value is emitted with
 * `confirm` so the parent can record it as a consent token in
 * the audit payload.
 *
 * Intentional behaviour:
 *   * ESC does NOT close — operator must explicitly Cancel. This
 *     mirrors GitHub's repo-delete UX and prevents accidental
 *     dismissal mid-typing.
 *   * The dialog never auto-fills the input — the operator must
 *     re-read what they are about to destroy.
 */
import { computed, nextTick, ref, watch } from 'vue';

const props = defineProps<{
  open: boolean;
  /** Headline shown in the title bar. */
  title: string;
  /** Explanatory paragraph above the input. */
  description: string;
  /** Exact token the operator must type to enable Confirm. */
  expected: string;
  /**
   * Free-form hint above the input. Defaults to "Type … to confirm".
   * Custom prompts let callers reuse the dialog for varied flows
   * (cluster name, replicaset name, "I ACCEPT DATA LOSS").
   */
  prompt?: string;
  /** Label for the Confirm button. */
  confirmLabel?: string;
  /** Action is in flight — disable both buttons. */
  pending?: boolean;
}>();

const emit = defineEmits<{
  /** Operator clicked Confirm with a matching input. */
  (e: 'confirm', token: string): void;
  /** Operator clicked Cancel. */
  (e: 'cancel'): void;
}>();

const input = ref('');
const inputEl = ref<HTMLInputElement | null>(null);

watch(
  () => props.open,
  async (now) => {
    if (now) {
      input.value = '';
      await nextTick();
      inputEl.value?.focus();
    }
  },
);

const matches = computed(() => input.value === props.expected);

function onConfirm() {
  if (!matches.value || props.pending) return;
  emit('confirm', input.value);
}
function onCancel() {
  if (props.pending) return;
  emit('cancel');
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="webui-destructive-dialog">
      <div
        class="webui-destructive-dialog__backdrop"
        @click="onCancel"
      />
      <div
        class="webui-destructive-dialog__panel"
        role="dialog"
        aria-modal="true"
      >
        <header class="webui-destructive-dialog__head">
          <h2 class="webui-destructive-dialog__title">{{ title }}</h2>
        </header>
        <div class="webui-destructive-dialog__body">
          <p class="webui-destructive-dialog__description">
            {{ description }}
          </p>
          <label class="webui-destructive-dialog__label">
            {{ prompt || `Type ${expected} to confirm:` }}
            <input
              ref="inputEl"
              v-model="input"
              type="text"
              autocomplete="off"
              spellcheck="false"
              class="webui-destructive-dialog__input"
              :disabled="pending"
              @keyup.enter="onConfirm"
            >
          </label>
        </div>
        <footer class="webui-destructive-dialog__foot">
          <button
            type="button"
            class="webui-destructive-dialog__btn webui-destructive-dialog__btn--ghost"
            :disabled="pending"
            @click="onCancel"
          >
            Cancel
          </button>
          <button
            type="button"
            class="webui-destructive-dialog__btn webui-destructive-dialog__btn--danger"
            :disabled="!matches || pending"
            @click="onConfirm"
          >
            {{ confirmLabel || 'Confirm' }}
          </button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.webui-destructive-dialog {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.webui-destructive-dialog__backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
}

.webui-destructive-dialog__panel {
  position: relative;
  width: min(520px, 92vw);
  border-radius: var(--webui-radius);
  background: var(--webui-bg-elevated);
  border: 1px solid var(--webui-border);
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
  display: flex;
  flex-direction: column;
  color: var(--webui-text);
}

.webui-destructive-dialog__head {
  padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--webui-border);
}

.webui-destructive-dialog__title {
  margin: 0;
  font-size: 1.05rem;
  font-weight: 600;
  color: var(--webui-danger);
}

.webui-destructive-dialog__body {
  padding: 1.25rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.webui-destructive-dialog__description {
  margin: 0;
  font-size: 0.92rem;
  line-height: 1.45;
  color: var(--webui-text-muted);
}

.webui-destructive-dialog__label {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  font-size: 0.9rem;
  font-weight: 500;
  color: var(--webui-text);
}

.webui-destructive-dialog__input {
  font-family: var(--webui-font-mono);
  font-size: 0.95rem;
  padding: 0.5rem 0.65rem;
  border: 1px solid var(--webui-border);
  border-radius: 5px;
  background: var(--webui-bg);
  color: var(--webui-text);
}

.webui-destructive-dialog__input:focus {
  outline: 2px solid var(--webui-accent);
  outline-offset: -1px;
}

.webui-destructive-dialog__foot {
  padding: 0.85rem 1.25rem;
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  border-top: 1px solid var(--webui-border);
}

.webui-destructive-dialog__btn {
  padding: 0.5rem 1rem;
  font-size: 0.92rem;
  border-radius: 5px;
  cursor: pointer;
  border: 1px solid transparent;
  font-weight: 500;
}

.webui-destructive-dialog__btn:disabled {
  cursor: not-allowed;
  opacity: 0.4;
}

.webui-destructive-dialog__btn--ghost {
  background: transparent;
  border-color: var(--webui-border);
  color: var(--webui-text);
}

.webui-destructive-dialog__btn--ghost:not(:disabled):hover {
  border-color: var(--webui-accent);
  color: var(--webui-accent);
}

.webui-destructive-dialog__btn--danger {
  background: var(--webui-danger);
  color: #0e1117;
  border-color: var(--webui-danger);
}

.webui-destructive-dialog__btn--danger:not(:disabled):hover {
  background: #fa6c66;
  border-color: #fa6c66;
  color: #0e1117;
}
</style>
