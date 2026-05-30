/**
 * Thin REST client used for non-GraphQL endpoints:
 *   /api/auth/login | /logout | /me
 *   /api/eval
 *   /api/metrics | /api/metrics/webui
 *   /api/health
 *   /api/config/download | /api/config/upload
 *   /api/diagnostics/bundle
 *
 * Every state-changing request carries `X-CSRF-Token`. 401/403 results
 * trigger the same navigation side-effects as the GraphQL client.
 *
 * The error envelope returned by the backend
 *   { error: { code, message, request_id, details? } }
 * is parsed and wrapped in `RestApiError` so call sites can switch on
 * a stable, typed `code` field.
 */

import { withTag } from '@/shared/lib/log';

const logger = withTag('rest');

type Method = 'GET' | 'POST' | 'PUT' | 'DELETE';

const STATE_CHANGING: ReadonlySet<Method> = new Set(['POST', 'PUT', 'DELETE']);

const readCsrfToken = (): string => {
  if (typeof document === 'undefined') return '';
  const match = document.cookie.match(/(?:^|;)\s*webui_csrf=([^;]+)/);
  return match ? decodeURIComponent(match[1]) : '';
};

export interface RestErrorBody {
  code: string;
  message: string;
  request_id?: string;
  details?: Record<string, unknown>;
}

export class RestApiError extends Error {
  readonly code: string;
  readonly status: number;
  readonly requestId: string | null;
  readonly details: Record<string, unknown> | null;

  constructor(body: RestErrorBody, status: number) {
    super(body.message);
    this.name = 'RestApiError';
    this.code = body.code;
    this.status = status;
    this.requestId = body.request_id ?? null;
    this.details = body.details ?? null;
  }
}

export interface RestErrorHandlers {
  onUnauthorized?: () => void;
  onForbidden?: () => void;
}

const defaultRestHandlers: Required<RestErrorHandlers> = {
  onUnauthorized: () => {
    if (typeof window !== 'undefined' && window.location.pathname !== '/login') {
      window.location.href = '/login?reason=unauthorized';
    }
  },
  onForbidden: () => {
    if (typeof window !== 'undefined' && window.location.pathname !== '/forbidden') {
      window.location.href = '/forbidden';
    }
  },
};

export interface RestRequestOptions {
  method?: Method;
  body?: unknown;
  /** Skip JSON encoding (e.g. file upload). */
  rawBody?: BodyInit;
  /** Skip automatic JSON parsing (e.g. blob download). */
  raw?: boolean;
  /** Headers merged with the defaults. */
  headers?: Record<string, string>;
  /** Per-request overrides for redirect handlers. */
  handlers?: RestErrorHandlers;
  /** AbortController signal for cancellation. */
  signal?: AbortSignal;
}

export class RestClient {
  private readonly basePath: string;
  private readonly handlers: Required<RestErrorHandlers>;

  constructor(basePath: string = '', handlers: RestErrorHandlers = {}) {
    this.basePath = basePath;
    this.handlers = { ...defaultRestHandlers, ...handlers };
  }

  async request<T = unknown>(path: string, opts: RestRequestOptions = {}): Promise<T> {
    const method = opts.method ?? 'GET';
    const url = this.basePath + path;
    const headers: Record<string, string> = {
      ...(opts.headers ?? {}),
    };
    if (STATE_CHANGING.has(method)) {
      const csrf = readCsrfToken();
      if (csrf) headers['x-csrf-token'] = csrf;
    }

    let body: BodyInit | undefined;
    if (opts.rawBody !== undefined) {
      body = opts.rawBody;
    } else if (opts.body !== undefined) {
      headers['content-type'] = headers['content-type'] ?? 'application/json';
      body = JSON.stringify(opts.body);
    }

    let response: Response;
    try {
      response = await fetch(url, {
        method,
        credentials: 'same-origin',
        headers,
        body,
        signal: opts.signal,
      });
    } catch (err) {
      logger.error('fetch failed', { url, method, err: (err as Error).message });
      throw err;
    }

    const requestId = response.headers.get('x-request-id');
    if (response.status === 401) {
      (opts.handlers?.onUnauthorized ?? this.handlers.onUnauthorized)();
    } else if (response.status === 403) {
      (opts.handlers?.onForbidden ?? this.handlers.onForbidden)();
    }

    if (response.ok) {
      if (opts.raw) {
        return response as unknown as T;
      }
      // Allow empty responses (204) to resolve to a typed null.
      if (response.status === 204) {
        return null as T;
      }
      return (await response.json()) as T;
    }

    // Non-2xx: try to parse the unified error envelope.
    let errorBody: RestErrorBody;
    try {
      const parsed = (await response.json()) as { error: RestErrorBody };
      errorBody = parsed.error;
    } catch {
      errorBody = {
        code: 'INTERNAL',
        message: `HTTP ${response.status}`,
        request_id: requestId ?? undefined,
      };
    }
    logger.warn('rest error', {
      url,
      method,
      status: response.status,
      code: errorBody.code,
      request_id: errorBody.request_id,
    });
    throw new RestApiError(errorBody, response.status);
  }

  get<T = unknown>(path: string, opts: Omit<RestRequestOptions, 'method' | 'body'> = {}) {
    return this.request<T>(path, { ...opts, method: 'GET' });
  }
  post<T = unknown>(path: string, body?: unknown, opts: Omit<RestRequestOptions, 'method' | 'body'> = {}) {
    return this.request<T>(path, { ...opts, method: 'POST', body });
  }
  put<T = unknown>(path: string, body?: unknown, opts: Omit<RestRequestOptions, 'method' | 'body'> = {}) {
    return this.request<T>(path, { ...opts, method: 'PUT', body });
  }
  delete<T = unknown>(path: string, opts: Omit<RestRequestOptions, 'method' | 'body'> = {}) {
    return this.request<T>(path, { ...opts, method: 'DELETE' });
  }
}

/** Default shared instance pointed at the local origin. */
export const restClient = new RestClient('');
