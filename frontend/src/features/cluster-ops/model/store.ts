/**
 * Cluster operator actions (Phase 5 minimal UI slice).
 *
 * Wraps the new `cluster_ops` GraphQL mutations behind a small
 * pinia store so cluster-page widgets can fire them without
 * importing urql directly. Every action exposes the same
 * `{ ok, message }` envelope the SPA reuses for inline banners.
 *
 * The store does NOT cache results — every call is one-shot. We
 * still surface a single `pending` flag because the cluster page
 * disables conflicting buttons while an action is in flight.
 */

import { defineStore } from 'pinia';
import { ref } from 'vue';

import {
  DemoteInstanceDocument,
  ExpelInstanceDocument,
  PauseFailoverDocument,
  PromoteInstanceDocument,
  ResumeFailoverDocument,
  SetInstanceStateDocument,
} from '@/shared/api/generated';
import { getClient } from '@/shared/api/graphql';
import { withTag } from '@/shared/lib/log';

const log = withTag('cluster-ops');

export interface ActionOutcome {
  ok: boolean;
  message: string;
  /** Typed error code from the GraphQL envelope when ok=false. */
  code?: string;
}

function shapeError(err: unknown, fallback: string): ActionOutcome {
  // urql wraps GraphQL errors in CombinedError. We surface the first
  // typed `extensions.code` so the UI can branch on FORBIDDEN /
  // NO_CHANGES / PAUSE_TTL_TOO_LONG / NOT_FOUND, and fall back to
  // the raw message otherwise.
  type GqlErr = { extensions?: { code?: string }; message?: string };
  type CombinedLike = { graphQLErrors?: GqlErr[]; message?: string };
  const e = err as CombinedLike;
  const first = e?.graphQLErrors?.[0];
  if (first) {
    return {
      ok: false,
      code: first.extensions?.code,
      message: first.message ?? fallback,
    };
  }
  return { ok: false, message: e?.message ?? fallback };
}

export const useClusterOpsStore = defineStore('cluster-ops', () => {
  const client = getClient();
  const pending = ref(false);

  async function pauseFailover(ttlSec?: number): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client
        .mutation(PauseFailoverDocument, { ttlSec })
        .toPromise();
      if (res.error) return shapeError(res.error, 'pauseFailover failed');
      const r = res.data?.pauseFailover;
      log.info('pauseFailover ok', { message: r?.message });
      return { ok: true, message: r?.message ?? 'paused' };
    } finally {
      pending.value = false;
    }
  }

  async function resumeFailover(): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client.mutation(ResumeFailoverDocument, {}).toPromise();
      if (res.error) return shapeError(res.error, 'resumeFailover failed');
      const r = res.data?.resumeFailover;
      log.info('resumeFailover ok', { message: r?.message });
      return { ok: true, message: r?.message ?? 'resumed' };
    } finally {
      pending.value = false;
    }
  }

  async function promoteInstance(
    alias: string,
    opts?: { ttlSec?: number; forceInconsistency?: boolean },
  ): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client
        .mutation(PromoteInstanceDocument, {
          alias,
          ttlSec: opts?.ttlSec,
          forceInconsistency: opts?.forceInconsistency,
        })
        .toPromise();
      if (res.error) return shapeError(res.error, 'promoteInstance failed');
      const r = res.data?.promoteInstance;
      log.info('promoteInstance ok', { alias, message: r?.message });
      return { ok: true, message: r?.message ?? 'promoted' };
    } finally {
      pending.value = false;
    }
  }

  async function demoteInstance(alias: string): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client
        .mutation(DemoteInstanceDocument, { alias })
        .toPromise();
      if (res.error) return shapeError(res.error, 'demoteInstance failed');
      const r = res.data?.demoteInstance;
      return { ok: true, message: r?.message ?? 'demoted' };
    } finally {
      pending.value = false;
    }
  }

  async function setInstanceState(
    alias: string,
    flags: { enabled?: boolean; electable?: boolean },
  ): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client
        .mutation(SetInstanceStateDocument, {
          alias,
          enabled: flags.enabled,
          electable: flags.electable,
        })
        .toPromise();
      if (res.error) return shapeError(res.error, 'setInstanceState failed');
      const r = res.data?.setInstanceState;
      return { ok: true, message: r?.message ?? 'state updated' };
    } finally {
      pending.value = false;
    }
  }

  async function expelInstance(
    alias: string,
    force = false,
  ): Promise<ActionOutcome> {
    pending.value = true;
    try {
      const res = await client
        .mutation(ExpelInstanceDocument, { alias, force })
        .toPromise();
      if (res.error) return shapeError(res.error, 'expelInstance failed');
      const r = res.data?.expelInstance;
      log.warn('expelInstance ok', { alias, message: r?.message });
      return { ok: true, message: r?.message ?? 'expelled' };
    } finally {
      pending.value = false;
    }
  }

  return {
    pending,
    pauseFailover,
    resumeFailover,
    promoteInstance,
    demoteInstance,
    setInstanceState,
    expelInstance,
  };
});
