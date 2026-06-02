/**
 * WebSocket subscriber for live cluster state.
 *
 * The backend pushes JSON snapshots after every poller tick (and
 * out-of-band on issues / suggestions transitions). The client
 * here is a lightweight singleton: it reconnects with exponential
 * backoff, emits parsed messages to subscribers, and exposes the
 * connection state so the UI can render a "live" indicator.
 *
 * Keeping the client transport-only avoids depending on Pinia
 * here — pages and stores subscribe via {@link onMessage} or
 * {@link onState}. The cluster store re-runs its urql queries on
 * each WS message rather than projecting the raw payload, which
 * keeps the TypeScript surface aligned with the GraphQL contract.
 */

import { withTag } from '@/shared/lib/log';

const log = withTag('ws');

export type WsConnectionState = 'idle' | 'connecting' | 'open' | 'closed' | 'reconnecting';

export interface WsMessage {
  type: 'initial' | 'snapshot' | string;
  generation?: number;
  ts?: number;
  cluster?: unknown;
  issues?: unknown;
  suggestions?: unknown;
  connection_id?: number;
  [k: string]: unknown;
}

type Listener<T> = (value: T) => void;

const MAX_BACKOFF_MS = 30_000;
const INITIAL_BACKOFF_MS = 500;

class WsClient {
  private socket: WebSocket | null = null;
  private state: WsConnectionState = 'idle';
  private attempt = 0;
  private url: string | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private destroyed = false;

  private messageListeners = new Set<Listener<WsMessage>>();
  private stateListeners = new Set<Listener<WsConnectionState>>();

  connect(url?: string) {
    if (this.socket && (this.state === 'open' || this.state === 'connecting')) {
      return;
    }
    this.destroyed = false;
    if (url) this.url = url;
    if (!this.url) this.url = defaultWsUrl();
    this.setState('connecting');
    log.debug('connecting', { url: this.url, attempt: this.attempt });
    try {
      const socket = new WebSocket(this.url);
      this.socket = socket;
      socket.addEventListener('open', () => {
        this.attempt = 0;
        this.setState('open');
        log.info('ws open');
      });
      socket.addEventListener('message', (event) => this.handleMessage(event));
      socket.addEventListener('error', (event) => {
        log.warn('ws error', { event: String(event.type) });
      });
      socket.addEventListener('close', (event) => {
        log.warn('ws closed', { code: event.code, reason: event.reason });
        this.socket = null;
        if (this.destroyed) {
          this.setState('closed');
          return;
        }
        this.scheduleReconnect();
      });
    } catch (err) {
      log.error('ws connect failed', { err: String(err) });
      this.scheduleReconnect();
    }
  }

  disconnect() {
    this.destroyed = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.socket) {
      try {
        this.socket.close(1000, 'client_disconnect');
      } catch {
        // ignore — socket is already detached
      }
      this.socket = null;
    }
    this.setState('closed');
  }

  onMessage(listener: Listener<WsMessage>): () => void {
    this.messageListeners.add(listener);
    return () => this.messageListeners.delete(listener);
  }

  onState(listener: Listener<WsConnectionState>): () => void {
    this.stateListeners.add(listener);
    listener(this.state);
    return () => this.stateListeners.delete(listener);
  }

  currentState(): WsConnectionState {
    return this.state;
  }

  private handleMessage(event: MessageEvent) {
    if (typeof event.data !== 'string') {
      log.debug('ws non-string message', { type: typeof event.data });
      return;
    }
    let parsed: WsMessage;
    try {
      parsed = JSON.parse(event.data) as WsMessage;
    } catch (err) {
      log.warn('ws parse failed', { err: String(err) });
      return;
    }
    log.debug('ws message', { type: parsed.type, bytes: event.data.length });
    for (const listener of this.messageListeners) {
      try {
        listener(parsed);
      } catch (err) {
        log.error('ws listener threw', { err: String(err) });
      }
    }
  }

  private setState(next: WsConnectionState) {
    if (this.state === next) return;
    this.state = next;
    for (const listener of this.stateListeners) {
      try {
        listener(next);
      } catch (err) {
        log.error('ws state listener threw', { err: String(err) });
      }
    }
  }

  private scheduleReconnect() {
    if (this.destroyed) return;
    this.attempt += 1;
    const delay = Math.min(INITIAL_BACKOFF_MS * 2 ** Math.min(this.attempt - 1, 6), MAX_BACKOFF_MS);
    this.setState('reconnecting');
    log.warn('ws scheduling reconnect', { attempt: this.attempt, delay_ms: delay });
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }
}

function defaultWsUrl(): string {
  if (typeof window === 'undefined') return 'ws://localhost:8081/ws';
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${window.location.host}/ws`;
}

// One singleton per app — the cluster view is a single subscriber
// surface and multiple sockets would just multiply backend cost.
export const wsClient = new WsClient();
