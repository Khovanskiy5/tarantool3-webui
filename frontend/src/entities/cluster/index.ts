/**
 * Public API of the cluster entity slice.
 *
 * Re-exports the urql-generated composable so pages can use the
 * query without importing through `@/shared/api/generated` — the
 * entity is the canonical place where the operation lives.
 */

export {
  useClusterOverviewQuery,
  useClusterServersPageQuery,
} from '@/shared/api/generated';

export type {
  ClusterOverview,
  ClusterServersPage,
  Server,
  Replicaset,
  ReplicasetStatus,
  ServerStatus,
} from './model/types';

export {
  getSelfAlias,
  getServers,
  getReplicasets,
  countServers,
  findServerByAlias,
  findReplicasetByName,
  formatRelativeSeconds,
  type ServerCounts,
} from './model/selectors';
