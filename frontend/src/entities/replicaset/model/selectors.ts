import type { Replicaset, ReplicasetRollup } from './types';

export function isHealthy(rs: Replicaset): boolean {
  return rs.status === 'healthy';
}

export function getLeaderAlias(rs: Replicaset): string | null {
  return rs.activeLeader ?? rs.leader ?? null;
}

export function getMemberAliases(rs: Replicaset): readonly string[] {
  return rs.servers.map((s) => s.alias);
}

export function asRollup(status: string): ReplicasetRollup {
  if (status === 'healthy' || status === 'degraded' || status === 'unhealthy') {
    return status;
  }
  return 'unknown';
}
