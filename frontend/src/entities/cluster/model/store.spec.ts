/**
 * Unit tests for the cluster Pinia store.
 *
 * The store talks to urql via the singleton client and to the WS
 * subscriber. Both are mocked here so the test stays hermetic:
 *
 *   - `getClient` is replaced with a stub whose `query` returns a
 *     pre-canned wonka-style result on toPromise().
 *   - `wsClient` is replaced with a stub whose `onMessage` /
 *     `onState` capture the listeners; the test triggers them
 *     directly.
 *
 * The store has internal asynchronous behaviour (`void refresh()`
 * on creation, plus the WS push triggering another refresh).
 * Tests pump the microtask queue with `await Promise.resolve()`
 * between actions.
 */

import { setActivePinia, createPinia } from 'pinia';
import { beforeEach, describe, expect, it, vi } from 'vitest';

type QueryResult = {
  data: unknown;
  error: { message: string } | null;
};
const queryResults: { initial: QueryResult; degraded: QueryResult } = {
  initial: {
    data: {
      cluster: {
        self: makeServer('tt-1'),
        servers: {
          items: [makeServer('tt-1'), makeServer('tt-2'), makeServer('tt-3')],
          nextCursor: null,
          totalCount: 3,
        },
        replicasets: [
          {
            name: 'rs-1',
            alias: 'rs-1',
            uuid: null,
            groupName: 'default',
            status: 'healthy',
            roles: [],
            weight: null,
            leader: null,
            activeLeader: 'tt-2',
            allRw: false,
            vshardGroup: null,
            servers: [
              { alias: 'tt-1', uuid: null, status: 'running', reachable: true },
              { alias: 'tt-2', uuid: null, status: 'running', reachable: true },
              { alias: 'tt-3', uuid: null, status: 'running', reachable: true },
            ],
          },
        ],
        knownRoles: [],
        vshardGroups: [],
      },
    },
    error: null,
  },
  degraded: {
    data: {
      cluster: {
        self: makeServer('tt-1'),
        servers: {
          items: [
            makeServer('tt-1'),
            { ...makeServer('tt-2'), reachable: false, status: 'unreachable' },
            makeServer('tt-3'),
          ],
          nextCursor: null,
          totalCount: 3,
        },
        replicasets: [
          {
            name: 'rs-1',
            alias: 'rs-1',
            uuid: null,
            groupName: 'default',
            status: 'degraded',
            roles: [],
            weight: null,
            leader: null,
            activeLeader: 'tt-3',
            allRw: false,
            vshardGroup: null,
            servers: [
              { alias: 'tt-1', uuid: null, status: 'running', reachable: true },
              { alias: 'tt-2', uuid: null, status: 'unreachable', reachable: false },
              { alias: 'tt-3', uuid: null, status: 'running', reachable: true },
            ],
          },
        ],
        knownRoles: [],
        vshardGroups: [],
      },
    },
    error: null,
  },
};

function makeServer(alias: string) {
  return {
    alias,
    uri: null,
    uuid: null,
    status: 'running',
    message: null,
    electable: true,
    replicasetName: 'rs-1',
    groupName: 'default',
    zone: null,
    reachable: true,
    lastSeen: null,
    lastError: null,
    nextRetryAt: null,
    configStatus: 'ready',
    labels: [],
    boxInfo: {
      uuid: `${alias}-uuid`,
      version: '3.7.0',
      uptime: 100,
      status: 'running',
      ro: alias === 'tt-2' ? false : true,
      roReason: alias === 'tt-2' ? null : 'election',
      vclock: '{}',
      replicasetUuid: null,
    },
    statistics: null,
  };
}

let nextQueryResult: QueryResult = queryResults.initial;
const queryMock = vi.fn(() => ({
  toPromise: () => Promise.resolve(nextQueryResult),
}));

vi.mock('@/shared/api/graphql', () => ({
  getClient: () => ({
    query: queryMock,
    mutation: vi.fn(),
  }),
}));

const wsListeners: Array<(msg: unknown) => void> = [];
const stateListeners: Array<(s: string) => void> = [];

vi.mock('@/shared/api/ws', () => ({
  wsClient: {
    currentState: () => 'open',
    onMessage: (l: (m: unknown) => void) => {
      wsListeners.push(l);
      return () => {
        const idx = wsListeners.indexOf(l);
        if (idx >= 0) wsListeners.splice(idx, 1);
      };
    },
    onState: (l: (s: string) => void) => {
      stateListeners.push(l);
      l('open');
      return () => {
        const idx = stateListeners.indexOf(l);
        if (idx >= 0) stateListeners.splice(idx, 1);
      };
    },
  },
}));

import { useClusterStore } from './store';

describe('useClusterStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    queryMock.mockClear();
    wsListeners.length = 0;
    stateListeners.length = 0;
    nextQueryResult = queryResults.initial;
  });

  it('runs an initial refresh on first use and exposes derived counters', async () => {
    const store = useClusterStore();
    await Promise.resolve();
    await Promise.resolve();

    expect(queryMock).toHaveBeenCalledTimes(1);
    expect(store.servers).toHaveLength(3);
    expect(store.replicasets).toHaveLength(1);
    expect(store.replicasets[0].status).toBe('healthy');
    expect(store.selfAlias).toBe('tt-1');
    expect(store.counts).toEqual({
      total: 3,
      reachable: 3,
      unreachable: 0,
      leaders: 1,
    });
  });

  it('refetches when a WS snapshot lands and reflects the new state', async () => {
    const store = useClusterStore();
    await Promise.resolve();
    await Promise.resolve();
    expect(store.counts.unreachable).toBe(0);

    nextQueryResult = queryResults.degraded;
    // Simulate the WS push that the cluster.poller would normally
    // emit. The listener is the one the store registered on
    // creation.
    expect(wsListeners).toHaveLength(1);
    wsListeners[0]({ type: 'snapshot', generation: 2 });
    await Promise.resolve();
    await Promise.resolve();

    expect(queryMock).toHaveBeenCalledTimes(2);
    expect(store.replicasets[0].status).toBe('degraded');
    expect(store.counts.unreachable).toBe(1);
  });

  it('ignores WS messages whose type is not snapshot/initial', async () => {
    const store = useClusterStore();
    await Promise.resolve();
    await Promise.resolve();

    wsListeners[0]({ type: 'pong' });
    wsListeners[0]({ type: 'whatever' });

    expect(queryMock).toHaveBeenCalledTimes(1);
    expect(store.servers).toHaveLength(3);
  });

  it('updates wsState ref when the connection state changes', async () => {
    const store = useClusterStore();
    await Promise.resolve();

    expect(stateListeners).toHaveLength(1);
    stateListeners[0]('reconnecting');
    expect(store.wsState).toBe('reconnecting');
    stateListeners[0]('open');
    expect(store.wsState).toBe('open');
  });

  it('captures GraphQL errors and exposes them via the error ref', async () => {
    nextQueryResult = { data: null, error: { message: 'boom' } };
    const store = useClusterStore();
    await Promise.resolve();
    await Promise.resolve();

    expect(store.error?.message).toBe('boom');
    expect(store.servers).toHaveLength(0);
  });
});
