/**
 * Global error boundary.
 *
 * Vue 3 has `app.config.errorHandler` for unhandled component errors
 * and `window.onerror` / `window.onunhandledrejection` for the rest.
 * Both feed into the shared structured logger so crashes show up with
 * the same shape as any other client log entry.
 *
 * The boundary deliberately does NOT rethrow: that would replace one
 * cryptic browser error with another. Instead, the user sees a toast
 * (once the toast utility lands in shared/ui), and the engineer sees
 * the structured log line.
 */

import type { App, ComponentPublicInstance } from 'vue';

import { withTag } from '@/shared/lib/log';

const logger = withTag('error-boundary');

export const installErrorBoundary = (app: App): void => {
  app.config.errorHandler = (
    err: unknown,
    instance: ComponentPublicInstance | null,
    info: string,
  ) => {
    logger.error('vue component error', {
      err: err instanceof Error ? err.message : String(err),
      stack: err instanceof Error ? err.stack : undefined,
      component: instance?.$options?.name ?? 'anonymous',
      info,
    });
  };

  if (typeof window !== 'undefined') {
    window.addEventListener('error', (event) => {
      logger.error('window error', {
        err: event.message,
        source: event.filename,
        line: event.lineno,
        col: event.colno,
      });
    });
    window.addEventListener('unhandledrejection', (event) => {
      logger.error('unhandled promise rejection', {
        reason:
          event.reason instanceof Error ? event.reason.message : String(event.reason ?? 'unknown'),
      });
    });
  }
};
