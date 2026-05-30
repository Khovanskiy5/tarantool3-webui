/**
 * Audit-entry store.
 *
 * Pulls from the GraphQL endpoint and supports filter + cursor
 * pagination. Pinia setup-store keeps the loading/error refs next
 * to the data and exposes a `load()` action the page reuses for
 * both initial fetch and "load more".
 */

import { defineStore } from 'pinia';
import { ref } from 'vue';

import { getClient } from '@/shared/api/graphql';
import { withTag } from '@/shared/lib/log';

import type { AuditEntry, AuditFilter, AuditPage } from './types';

const logger = withTag('audit');

const AUDIT_QUERY = /* GraphQL */ `
  query AuditQuery($filter: AuditFilter, $limit: Int, $after: Long) {
    audit(filter: $filter, limit: $limit, after: $after) {
      entries {
        id
        ts
        user
        action
        scope
        request_id
        payload
      }
      next_cursor
      has_more
    }
  }
`;

export const useAuditStore = defineStore('audit', () => {
  const entries  = ref<AuditEntry[]>([]);
  const cursor   = ref<number | null>(null);
  const hasMore  = ref(false);
  const pending  = ref(false);
  const error    = ref<string | null>(null);
  const currentFilter = ref<AuditFilter>({});

  const load = async (
    filter: AuditFilter = {},
    opts: { append?: boolean; limit?: number } = {},
  ): Promise<void> => {
    pending.value = true;
    error.value = null;
    try {
      if (!opts.append) {
        entries.value = [];
        cursor.value = null;
        currentFilter.value = filter;
      }
      const client = getClient();
      const variables = {
        filter,
        limit: opts.limit ?? 50,
        after: opts.append ? cursor.value : null,
      };
      const res = await client.query<{ audit: AuditPage }>(AUDIT_QUERY, variables).toPromise();
      if (res.error) {
        error.value = res.error.message;
        return;
      }
      const page = res.data?.audit;
      if (page == null) return;
      if (opts.append) {
        entries.value = entries.value.concat(page.entries);
      } else {
        entries.value = page.entries;
      }
      cursor.value = page.next_cursor;
      hasMore.value = page.has_more;
    } catch (err) {
      error.value = (err as Error).message;
      logger.warn('audit load failed', { err: error.value });
    } finally {
      pending.value = false;
    }
  };

  return {
    entries,
    cursor,
    hasMore,
    pending,
    error,
    currentFilter,
    load,
  };
});
