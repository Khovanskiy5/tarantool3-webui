/**
 * Pure derivation helpers over the ClusterOverview snapshot.
 *
 * Components consume these selectors instead of poking the raw
 * GraphQL shape — keeps the call sites lean and the derived fields
 * (counts, leader resolution, replicaset rollups) consistent across
 * the UI.
 */

import type { ClusterOverview, Replicaset, Server } from './types';

export function getSelfAlias(cluster: ClusterOverview | null | undefined): string | null {
  return cluster?.self?.alias ?? null;
}

export function getServers(cluster: ClusterOverview | null | undefined): readonly Server[] {
  return cluster?.servers.items ?? [];
}

export function getReplicasets(cluster: ClusterOverview | null | undefined): readonly Replicaset[] {
  return cluster?.replicasets ?? [];
}

export interface ServerCounts {
  readonly total: number;
  readonly reachable: number;
  readonly unreachable: number;
  readonly leaders: number;
}

export function countServers(servers: readonly Server[]): ServerCounts {
  let reachable = 0;
  let leaders = 0;
  for (const s of servers) {
    if (s.reachable) reachable += 1;
    if (s.boxInfo?.ro === false) leaders += 1;
  }
  return {
    total: servers.length,
    reachable,
    unreachable: servers.length - reachable,
    leaders,
  };
}

export function findServerByAlias(servers: readonly Server[], alias: string): Server | null {
  return servers.find((s) => s.alias === alias) ?? null;
}

export function findReplicasetByName(
  replicasets: readonly Replicaset[],
  name: string,
): Replicaset | null {
  return replicasets.find((r) => r.name === name) ?? null;
}

/**
 * Pretty-print an `lastSeen` / `nextRetryAt` value as a relative
 * description ("just now", "5s ago", "in 12s"). Returns null when
 * the source value is null.
 */
export function formatRelativeSeconds(
  value: number | null | undefined,
  now: number,
): string | null {
  if (value == null) return null;
  const delta = value - now;
  const abs = Math.abs(delta);
  if (abs < 1) return 'just now';
  const unit = abs < 60 ? `${Math.round(abs)}s` : `${Math.round(abs / 60)}m`;
  return delta < 0 ? `${unit} ago` : `in ${unit}`;
}
