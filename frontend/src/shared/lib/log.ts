/**
 * Structured client logger.
 *
 * Levels: debug < info < warn < error.
 * Default level: derived from VITE_LOG_LEVEL (env), falling back to
 *  - "debug" in dev (import.meta.env.DEV === true)
 *  - "warn"  in prod
 *
 * The logger emits to the browser console with a stable shape that
 * mirrors backend structured logs:
 *   { ts, level, tag, msg, ...fields }
 *
 * No metatables, no overlapping APIs: tagged loggers are plain objects
 * of closures created by withTag().
 *
 * Critical client errors will also be POSTed to a backend collector in a
 * later task; this module exposes a single `subscribeSink` hook for that.
 */

type Level = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  ts: string;
  level: Level;
  tag: string;
  msg: string;
  [key: string]: unknown;
}

type Sink = (entry: LogEntry) => void;

const LEVEL_ORDER: Record<Level, number> = { debug: 1, info: 2, warn: 3, error: 4 };
const DEFAULT_TAG = 'general';
const VALID_LEVELS = new Set<Level>(['debug', 'info', 'warn', 'error']);

const isLevel = (v: unknown): v is Level => typeof v === 'string' && VALID_LEVELS.has(v as Level);

const resolveDefaultLevel = (): Level => {
  const fromEnv = import.meta.env.VITE_LOG_LEVEL;
  if (isLevel(fromEnv)) return fromEnv;
  return import.meta.env.DEV ? 'debug' : 'warn';
};

const state = {
  level: resolveDefaultLevel(),
  sinks: [] as Sink[],
};

const timestamp = (): string => new Date().toISOString();

const consoleSink: Sink = (entry) => {
  // Console gets a compact pretty-print in dev, JSON in prod, so prod
  // logs ship cleanly into observability sinks that scrape console.
  if (import.meta.env.DEV) {
    const tail = Object.entries(entry)
      .filter(([k]) => !['ts', 'level', 'tag', 'msg'].includes(k))
      .map(([k, v]) => `${k}=${JSON.stringify(v)}`)
      .join(' ');
    console[entry.level === 'debug' ? 'log' : entry.level](
      `[${entry.tag}] ${entry.msg}${tail ? ' ' + tail : ''}`,
    );
  } else {
    console[entry.level === 'debug' ? 'log' : entry.level](JSON.stringify(entry));
  }
};

const emit = (level: Level, tag: string, msg: string, fields?: Record<string, unknown>): void => {
  if (LEVEL_ORDER[level] < LEVEL_ORDER[state.level]) return;
  const entry: LogEntry = { ts: timestamp(), level, tag, msg };
  if (fields) {
    for (const [k, v] of Object.entries(fields)) {
      if (entry[k] === undefined) entry[k] = v;
    }
  }
  consoleSink(entry);
  for (const sink of state.sinks) {
    try {
      sink(entry);
    } catch {
      // Sinks must not break the call site; swallow and continue.
    }
  }
};

export const configure = (opts: { level?: Level }): void => {
  if (opts.level && isLevel(opts.level)) state.level = opts.level;
};

export const currentLevel = (): Level => state.level;

export const subscribeSink = (sink: Sink): (() => void) => {
  state.sinks.push(sink);
  return () => {
    state.sinks = state.sinks.filter((s) => s !== sink);
  };
};

export interface TaggedLogger {
  debug: (msg: string, fields?: Record<string, unknown>) => void;
  info: (msg: string, fields?: Record<string, unknown>) => void;
  warn: (msg: string, fields?: Record<string, unknown>) => void;
  error: (msg: string, fields?: Record<string, unknown>) => void;
}

export const withTag = (tag: string): TaggedLogger => {
  const t = typeof tag === 'string' && tag.length > 0 ? tag : DEFAULT_TAG;
  return {
    debug: (msg, fields) => emit('debug', t, msg, fields),
    info: (msg, fields) => emit('info', t, msg, fields),
    warn: (msg, fields) => emit('warn', t, msg, fields),
    error: (msg, fields) => emit('error', t, msg, fields),
  };
};

// Untagged convenience.
export const debug = (msg: string, fields?: Record<string, unknown>): void =>
  emit('debug', DEFAULT_TAG, msg, fields);
export const info = (msg: string, fields?: Record<string, unknown>): void =>
  emit('info', DEFAULT_TAG, msg, fields);
export const warn = (msg: string, fields?: Record<string, unknown>): void =>
  emit('warn', DEFAULT_TAG, msg, fields);
export const error = (msg: string, fields?: Record<string, unknown>): void =>
  emit('error', DEFAULT_TAG, msg, fields);
