/**
 * Cluster-level types projected from the GraphQL schema.
 *
 * The codegen output (`@/shared/api/generated.ts`) is the source of
 * truth for field names. This module re-exports the operation
 * result types under domain-friendly aliases so consumers
 * (widgets, pages) do not depend on graphql-codegen naming
 * conventions in their imports.
 */

import type {
  ClusterOverviewQuery,
  ClusterServersPageQuery,
  ServerCardFieldsFragment,
  ReplicasetCardFieldsFragment,
} from '@/shared/api/generated';

export type ClusterOverview = NonNullable<ClusterOverviewQuery['cluster']>;
export type ClusterServersPage = NonNullable<
  ClusterServersPageQuery['cluster']
>['servers'];

export type Server = ServerCardFieldsFragment;
export type Replicaset = ReplicasetCardFieldsFragment;

export type ReplicasetStatus =
  | 'healthy'
  | 'degraded'
  | 'unhealthy'
  | 'unknown';

export type ServerStatus = string;
