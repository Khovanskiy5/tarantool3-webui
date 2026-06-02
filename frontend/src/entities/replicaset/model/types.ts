/**
 * Replicaset entity types. The replicaset is a subset of the cluster
 * overview, but the slice exists so widgets that show a single
 * replicaset (cluster-topology, failover panel) can import a focused
 * type without dragging the full ClusterOverview into their props.
 */

import type { ReplicasetCardFieldsFragment } from '@/shared/api/generated';

export type Replicaset = ReplicasetCardFieldsFragment;

export type ReplicasetRollup = 'healthy' | 'degraded' | 'unhealthy' | 'unknown';
