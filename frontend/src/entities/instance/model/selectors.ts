import type { Instance, InstanceReachability } from './types';

export function reachability(instance: Instance): InstanceReachability {
  if (instance.reachable) return 'reachable';
  // `lastSeen != null` means we did reach this peer before; the
  // current outage is therefore a real partition rather than a
  // never-seen peer.
  return instance.lastSeen != null ? 'unreachable' : 'unknown';
}

export function isLeader(instance: Instance): boolean {
  return instance.boxInfo?.ro === false;
}

export function shortUuid(uuid: string | null | undefined): string {
  if (!uuid) return '—';
  return `${uuid.slice(0, 8)}…`;
}
