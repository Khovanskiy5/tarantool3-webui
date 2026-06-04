import type { Instance, InstanceReachability } from './types';

export function reachability(instance: Instance): InstanceReachability {
  if (instance.reachable) return 'reachable';
  // `lastSeen != null` means we did reach this peer before; the
  // current outage is therefore a real partition rather than a
  // never-seen peer.
  return instance.lastSeen != null ? 'unreachable' : 'unknown';
}

// Whether THIS instance is the leader of `leaderAlias`'s
// replicaset. `box.info.ro === false` alone is misleading under
// the supervised-failover agent: every peer declares
// `database.mode: rw` so synchro-queue ownership (not the `ro`
// flag) is the real single-writer lock — all three peers can
// have ro=false while the queue belongs to exactly one. The
// caller passes the replicaset's appointed leader alias so we
// can compare directly.
export function isLeader(instance: Instance, leaderAlias: string | null | undefined): boolean {
  if (leaderAlias != null) {
    return instance.alias === leaderAlias;
  }
  // Fallback for callers that haven't plumbed the leader alias
  // yet (e.g. legacy views): retain the old heuristic so behaviour
  // does not regress for replicasets in `failover: election` mode
  // where exactly one peer is RW.
  return instance.boxInfo?.ro === false;
}

// Docker-style short id: the trailing hex group of the instance UUID
// (its last 12 chars), shown in a monospace cell with the full UUID in a
// tooltip — mirrors how `docker ps` renders container ids.
export function containerId(uuid: string | null | undefined): string {
  if (!uuid) return '—';
  const tail = uuid.includes('-') ? uuid.slice(uuid.lastIndexOf('-') + 1) : uuid;
  return tail.slice(-12);
}

// Short semver for the table column: drop the build suffix, e.g.
// "3.7.0-0-g78b01ace947d" -> "3.7.0". The full string lives in the
// cell's tooltip.
export function shortVersion(version: string | null | undefined): string {
  if (!version) return '—';
  return version.split('-')[0];
}
