/**
 * Issues store. Talks to the urql singleton directly so the store
 * factory can run outside Vue's component context — same reasoning
 * as the cluster store.
 */

import { defineStore } from 'pinia';
import { computed, onScopeDispose, ref, shallowRef, watch } from 'vue';

import {
  IssuesPageDocument,
  IssuesSummaryDocument,
  type IssueCategory as GqlIssueCategory,
  type IssueScope as GqlIssueScope,
  type IssueSeverity as GqlIssueSeverity,
  type IssuesPageQuery,
  type IssuesPageQueryVariables,
  type IssuesSummaryQuery,
} from '@/shared/api/generated';
import { getClient } from '@/shared/api/graphql';
import { wsClient } from '@/shared/api/ws';
import { withTag } from '@/shared/lib/log';

import type { Issue } from './types';

const log = withTag('issue-store');

export interface IssueFilters {
  severity: GqlIssueSeverity | null;
  scope: GqlIssueScope | null;
  category: GqlIssueCategory | null;
  instance: string | null;
  replicaset: string | null;
}

const EMPTY_FILTERS: IssueFilters = {
  severity: null,
  scope: null,
  category: null,
  instance: null,
  replicaset: null,
};

export const useIssueStore = defineStore('issues', () => {
  const client = getClient();
  const filters = ref<IssueFilters>({ ...EMPTY_FILTERS });
  const list = shallowRef<IssuesPageQuery | null>(null);
  const summaryData = shallowRef<IssuesSummaryQuery | null>(null);
  const fetching = ref(false);

  async function fetchList() {
    const vars: IssuesPageQueryVariables = {
      severity: filters.value.severity,
      scope: filters.value.scope,
      category: filters.value.category,
      instance: filters.value.instance,
      replicaset: filters.value.replicaset,
      limit: 200,
      after: null,
    };
    const result = await client
      .query(IssuesPageDocument, vars, { requestPolicy: 'network-only' })
      .toPromise();
    if (!result.error) list.value = result.data ?? null;
    else log.warn('issues query error', { err: result.error.message });
  }

  async function fetchSummary() {
    const result = await client
      .query(IssuesSummaryDocument, {}, { requestPolicy: 'network-only' })
      .toPromise();
    if (!result.error) summaryData.value = result.data ?? null;
    else log.warn('issuesSummary query error', { err: result.error.message });
  }

  async function refresh() {
    fetching.value = true;
    try {
      await Promise.all([fetchList(), fetchSummary()]);
    } finally {
      fetching.value = false;
    }
  }

  void refresh();
  watch(filters, () => void fetchList(), { deep: true });

  const unsubMsg = wsClient.onMessage((msg) => {
    if (msg.type === 'snapshot' || msg.type === 'initial') {
      log.debug('ws -> issues refetch', { gen: msg.generation });
      void refresh();
    }
  });
  onScopeDispose(() => {
    unsubMsg();
  });

  const items = computed<readonly Issue[]>(() => list.value?.issues.items ?? []);
  const total = computed<number>(() => list.value?.issues.totalCount ?? 0);
  const summary = computed(
    () =>
      summaryData.value?.issuesSummary ?? {
        warning: 0,
        critical: 0,
        total: 0,
      },
  );

  function setFilters(patch: Partial<IssueFilters>) {
    filters.value = { ...filters.value, ...patch };
  }

  function resetFilters() {
    filters.value = { ...EMPTY_FILTERS };
  }

  return {
    filters,
    items,
    total,
    summary,
    fetching,
    setFilters,
    resetFilters,
    refresh,
  };
});
