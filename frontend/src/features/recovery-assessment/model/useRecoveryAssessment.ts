/**
 * Reusable risk-assessment orchestration (RC-5 / RC-6).
 *
 * Drives the unified recovery flow for ANY action: read-only
 * `recoveryPreflight` -> assessment panel -> enforced `recoveryAction`
 * (acknowledge + typed token + decision fingerprint + idempotency key).
 * `safe`/`caution` apply with one click; `dangerous` gates behind the
 * panel's ack + token. The server re-checks the fingerprint and a
 * `STALE_FINGERPRINT` reply transparently re-runs preflight.
 *
 * Extracted from ClusterRecovery.vue so the page wizards AND the global
 * Suggestions banner share one code path — the plan's invariant 8
 * ("единая модель на все аналогичные функции").
 */
import { ref } from 'vue';

import { getClient } from '@/shared/api/graphql';

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
export interface ActionResult {
  ok: boolean;
  action: string;
  error?: string | null;
  results: { peer: string; ok: boolean; msg: string | null }[];
}

const PREFLIGHT_Q = /* GraphQL */ `
  query DrPreflight($action: String!, $payload: String) {
    recoveryPreflight(action: $action, payload: $payload) {
      action
      risk
      dataLoss
      autoSafe
      summary
      effects
      warnings
      manualRecovery
      preconditions {
        ok
        label
        detail
      }
      failureCommands {
        title
        command
        note
      }
      confirm {
        required
        token
        acknowledge
      }
      docs
      fingerprint
    }
  }
`;

// Exported so callers can drive read-only diagnose pseudo-actions
// (e.g. `topology_fix_diagnose`, `wal_diagnose`) through the same
// `recoveryAction` mutation without re-declaring the document.
export const RECOVERY_ACTION_MUTATION = /* GraphQL */ `
  mutation DrAction(
    $action: String!
    $payload: String
    $acknowledge: Boolean
    $confirmToken: String
    $fingerprint: String
    $idempotencyKey: String
  ) {
    recoveryAction(
      action: $action
      payload: $payload
      acknowledge: $acknowledge
      confirmToken: $confirmToken
      fingerprint: $fingerprint
      idempotencyKey: $idempotencyKey
    ) {
      ok
      action
      error
      results {
        peer
        ok
        msg
      }
    }
  }
`;

function newIdempotencyKey(): string {
  if (
    typeof globalThis.crypto !== 'undefined' &&
    typeof globalThis.crypto.randomUUID === 'function'
  ) {
    return globalThis.crypto.randomUUID();
  }
  return 'rc-' + Date.now() + '-' + Math.random().toString(36).slice(2);
}

export interface UseRecoveryAssessmentOptions {
  /** Called after a successful apply with the action result. */
  onApplied?: (result: ActionResult | null) => void | Promise<void>;
}

export function useRecoveryAssessment(options: UseRecoveryAssessmentOptions = {}) {
  const assessOpen = ref(false);
  const assessBusy = ref(false);
  const assessment = ref<Assessment | null>(null);
  const assessAck = ref(false);
  const assessToken = ref('');
  const assessError = ref<string | null>(null);
  let assessAction = '';
  let assessPayload: string | null = null;

  async function runPreflight(): Promise<boolean> {
    assessError.value = null;
    const res = await getClient()
      .query<{
        recoveryPreflight: Assessment;
      }>(
        PREFLIGHT_Q,
        { action: assessAction, payload: assessPayload },
        { requestPolicy: 'network-only' },
      )
      .toPromise();
    if (res.error) {
      assessError.value = res.error.message;
      return false;
    }
    assessment.value = res.data?.recoveryPreflight ?? null;
    return assessment.value !== null;
  }

  // Open the assessment panel for an (action, payload).
  async function openAssessment(action: string, payload: string | null) {
    assessAction = action;
    assessPayload = payload;
    assessment.value = null;
    assessAck.value = false;
    assessToken.value = '';
    assessError.value = null;
    assessOpen.value = true;
    assessBusy.value = true;
    try {
      await runPreflight();
    } finally {
      assessBusy.value = false;
    }
  }

  // Apply the assessed action with the enforcement context. On a stale
  // fingerprint, refresh the preflight and ask the operator to retry.
  async function applyAssessed() {
    const a = assessment.value;
    if (!a) return;
    assessBusy.value = true;
    assessError.value = null;
    try {
      const res = await getClient()
        .mutation<{ recoveryAction: ActionResult }>(RECOVERY_ACTION_MUTATION, {
          action: assessAction,
          payload: assessPayload,
          acknowledge: a.confirm.required ? assessAck.value : null,
          confirmToken: a.confirm.required ? assessToken.value.trim() : null,
          fingerprint: a.fingerprint,
          idempotencyKey: newIdempotencyKey(),
        })
        .toPromise();
      if (res.error) {
        assessError.value = res.error.message;
        return;
      }
      const r = res.data?.recoveryAction ?? null;
      if (r && !r.ok && (r.error ?? '').startsWith('STALE_FINGERPRINT')) {
        // Cluster state moved since preflight — re-assess and ask again.
        assessAck.value = false;
        assessToken.value = '';
        await runPreflight();
        assessError.value = 'Cluster state changed — review the refreshed summary.';
        return;
      }
      assessOpen.value = false;
      await options.onApplied?.(r);
    } finally {
      assessBusy.value = false;
    }
  }

  return {
    assessOpen,
    assessBusy,
    assessment,
    assessAck,
    assessToken,
    assessError,
    openAssessment,
    applyAssessed,
  };
}
