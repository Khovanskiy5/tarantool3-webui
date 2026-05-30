/**
 * Unit tests for the WebSocket singleton client.
 *
 * `vitest-websocket-mock` spins up an in-memory WebSocket server
 * that the browser's native `WebSocket` constructor connects to.
 * We do not exercise the real network — instead the mock server
 * sends frames we control and we assert on listener behavior.
 *
 * The tests use `wsClient` directly because it is the singleton
 * the rest of the app shares. `beforeEach` calls `disconnect()`
 * to reset state and `WS.clean()` to drop any lingering mock
 * servers from previous specs.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import WS from 'vitest-websocket-mock';

import { wsClient, type WsMessage, type WsConnectionState } from './client';

const URL = 'ws://localhost:1234/ws';

describe('wsClient', () => {
  let server: WS;

  beforeEach(() => {
    server = new WS(URL, { jsonProtocol: false });
    // Ensure no listeners or previous connection survive across tests.
    wsClient.disconnect();
  });

  afterEach(() => {
    wsClient.disconnect();
    WS.clean();
  });

  it('opens a connection and reports state transitions', async () => {
    const states: WsConnectionState[] = [];
    wsClient.onState((s) => states.push(s));

    wsClient.connect(URL);
    await server.connected;

    expect(states).toContain('connecting');
    expect(states).toContain('open');
    expect(wsClient.currentState()).toBe('open');
  });

  it('parses JSON messages and dispatches them to subscribers', async () => {
    const received: WsMessage[] = [];
    wsClient.onMessage((msg) => received.push(msg));

    wsClient.connect(URL);
    await server.connected;

    const payload = {
      type: 'snapshot' as const,
      generation: 42,
      cluster: { foo: 'bar' },
      issues: [],
      suggestions: {},
      ts: 1.5,
    };
    server.send(JSON.stringify(payload));

    // Vitest message events fire synchronously inside the mock.
    expect(received).toHaveLength(1);
    expect(received[0].type).toBe('snapshot');
    expect(received[0].generation).toBe(42);
  });

  it('ignores invalid JSON without crashing the listener loop', async () => {
    const received: WsMessage[] = [];
    wsClient.onMessage((msg) => received.push(msg));

    wsClient.connect(URL);
    await server.connected;

    server.send('this is not json');
    server.send('{"type": "initial", "generation": 1}');

    expect(received).toHaveLength(1);
    expect(received[0].generation).toBe(1);
  });

  it('protects subscribers from each other when one throws', async () => {
    const seen: number[] = [];
    wsClient.onMessage(() => {
      throw new Error('first subscriber boom');
    });
    wsClient.onMessage((msg) => {
      if (typeof msg.generation === 'number') seen.push(msg.generation);
    });

    wsClient.connect(URL);
    await server.connected;

    server.send('{"type":"snapshot","generation":7}');

    expect(seen).toEqual([7]);
  });

  it('unsubscribe stops the listener from receiving further messages', async () => {
    const received: WsMessage[] = [];
    const off = wsClient.onMessage((msg) => received.push(msg));

    wsClient.connect(URL);
    await server.connected;
    server.send('{"type":"snapshot","generation":1}');
    off();
    server.send('{"type":"snapshot","generation":2}');

    expect(received.map((m) => m.generation)).toEqual([1]);
  });

  it('moves to "reconnecting" after an unexpected close', async () => {
    const states: WsConnectionState[] = [];
    wsClient.onState((s) => states.push(s));

    wsClient.connect(URL);
    await server.connected;

    server.close();
    // Yield once so the mock's close event reaches the WS client.
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(states.at(-1)).toBe('reconnecting');
    expect(wsClient.currentState()).toBe('reconnecting');
  });

  it('disconnect flips state to closed even from the reconnecting window', async () => {
    wsClient.connect(URL);
    await server.connected;

    server.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(wsClient.currentState()).toBe('reconnecting');

    // disconnect() clears the pending reconnect timer and marks
    // the client as destroyed so the scheduled reconnect can no
    // longer fire. After this call the public state moves to
    // 'closed' immediately.
    wsClient.disconnect();
    expect(wsClient.currentState()).toBe('closed');
  });

  it('onState replays the current state synchronously on subscribe', () => {
    const got: WsConnectionState[] = [];
    wsClient.onState((s) => got.push(s));
    expect(got).toEqual([wsClient.currentState()]);
  });
});
