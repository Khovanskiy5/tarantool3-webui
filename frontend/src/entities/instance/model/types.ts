/**
 * Instance entity types. "Instance" and "Server" are the same node
 * in the cluster topology; this slice exposes per-instance views
 * (instance-detail page, instance probe widget) without leaking the
 * cluster aggregate shape.
 */

import type { ServerCardFieldsFragment } from '@/shared/api/generated';

export type Instance = ServerCardFieldsFragment;

export type InstanceReachability = 'reachable' | 'unreachable' | 'unknown';
