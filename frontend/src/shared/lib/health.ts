/**
 * Client-side wrapper around `/api/health`.
 *
 * The endpoint is the cheapest readable identity signal the backend
 * exposes: it returns instance name, role state, uptime and version
 * strings without any auth dance. Several widgets need that
 * information before the cluster entity store (Task 17) lands —
 * notably TopBar, which must show the current instance, and the
 * error-boundary, which surfaces a degradation banner.
 *
 * The composable is intentionally small:
 *   - one shared ref per app (singleton via module scope),
 *   - one in-flight promise so concurrent callers do not stampede,
 *   - a manual `refresh()` for components that want to force a poll.
 *
 * Once the cluster entity store lands, this module becomes its
 * implementation detail; callers will keep using `useHealth()` and
 * not notice the swap.
 */

import { readonly, ref, type Ref } from 'vue';

import { withTag } from '@/shared/lib/log';

const log = withTag('health');

export interface HealthSnapshot {
  status: 'ok' | 'degraded' | 'unhealthy';
  instance: string;
  role_state: string;
  uptime_sec: number;
  webui_version: string;
  tarantool_version: string;
  checks: Record<string, string>;
}

const snapshot = ref<HealthSnapshot | null>(null);
const error = ref<Error | null>(null);
let inflight: Promise<HealthSnapshot | null> | null = null;

async function fetchHealth(): Promise<HealthSnapshot | null> {
  try {
    const res = await fetch('/api/health', {
      credentials: 'same-origin',
      headers: { accept: 'application/json' },
    });
    if (!res.ok) {
      throw new Error(`/api/health responded ${res.status}`);
    }
    const body = (await res.json()) as HealthSnapshot;
    snapshot.value = body;
    error.value = null;
    return body;
  } catch (err) {
    const wrapped = err instanceof Error ? err : new Error(String(err));
    error.value = wrapped;
    log.warn('health probe failed', { err: wrapped.message });
    return null;
  } finally {
    inflight = null;
  }
}

export function refreshHealth(): Promise<HealthSnapshot | null> {
  if (!inflight) inflight = fetchHealth();
  return inflight;
}

export function useHealth(): {
  snapshot: Readonly<Ref<HealthSnapshot | null>>;
  error: Readonly<Ref<Error | null>>;
  refresh: typeof refreshHealth;
} {
  // First caller kicks off the initial probe; subsequent callers
  // reuse the cached snapshot until refresh() is asked for.
  if (snapshot.value === null && inflight === null) {
    void refreshHealth();
  }
  return {
    snapshot: readonly(snapshot),
    error: readonly(error),
    refresh: refreshHealth,
  };
}
