/**
 * Vitest coverage for HistoryPanel — render shape and emit contract.
 *
 * The component talks to urql via the singleton client; we mock the
 * client with a queue of pre-canned QueryResult values so each test
 * controls exactly what the panel sees. PrimeVue Button is replaced
 * with a transparent stub — it lives outside the contract we're
 * testing (the panel emits events; whether the button is PrimeVue or
 * a <button> is a styling concern).
 */

import { mount, flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import HistoryPanel from './HistoryPanel.vue';

type QueryResult = {
  data: { configHistory: unknown } | null;
  error: { message: string } | null;
};

let nextQueryResult: QueryResult = {
  data: { configHistory: { revisions: [], oldest_available_revision: null, more: false } },
  error: null,
};

const queryMock = vi.fn(() => ({
  toPromise: () => Promise.resolve(nextQueryResult),
}));

vi.mock('@/shared/api/graphql', () => ({
  getClient: () => ({ query: queryMock, mutation: vi.fn() }),
}));

const ButtonStub = {
  name: 'Button',
  props: ['label', 'icon', 'disabled', 'loading', 'severity', 'size', 'text', 'outlined'],
  emits: ['click'],
  template: '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const baseRevisions = [
  { revision: 12, ts: 1717000000, user: 'admin_dev', hash: 'abcdef0123456789', size: 1024, action: 'commit' },
  { revision: 11, ts: 1716999000, user: 'operator_dev', hash: 'fedcba9876543210', size: 1000, action: 'commit' },
  { revision: 10, ts: 1716998000, user: null, hash: null, size: null, action: 'rollback' },
];

const mountPanel = (currentRevision: number | null = 12) =>
  mount(HistoryPanel, {
    props: { currentRevision },
    global: { stubs: { Button: ButtonStub } },
  });

beforeEach(() => {
  queryMock.mockClear();
  nextQueryResult = {
    data: {
      configHistory: {
        revisions: baseRevisions,
        oldest_available_revision: 5,
        more: false,
      },
    },
    error: null,
  };
});

afterEach(() => {
  vi.clearAllMocks();
});

describe('HistoryPanel', () => {
  it('fetches configHistory on mount and renders every revision row', async () => {
    const wrapper = mountPanel();
    await flushPromises();

    expect(queryMock).toHaveBeenCalledTimes(1);
    const rows = wrapper.findAll('.webui-history__row');
    expect(rows).toHaveLength(3);
    expect(rows[0].text()).toContain('#12');
    expect(rows[1].text()).toContain('#11');
    expect(rows[2].text()).toContain('#10');
  });

  it('marks the row that matches currentRevision as active', async () => {
    const wrapper = mountPanel(11);
    await flushPromises();

    const rows = wrapper.findAll('.webui-history__row');
    const active = rows.filter((row) => row.classes('webui-history__row--active'));
    expect(active).toHaveLength(1);
    expect(active[0].text()).toContain('#11');
  });

  it('surfaces oldest_available_revision in the footer hint', async () => {
    const wrapper = mountPanel();
    await flushPromises();

    const footer = wrapper.find('.webui-history__floor');
    expect(footer.exists()).toBe(true);
    expect(footer.text()).toContain('#5');
    expect(footer.text()).toContain('MAX_HISTORY');
  });

  it('renders the empty state when no revisions are returned', async () => {
    nextQueryResult = {
      data: { configHistory: { revisions: [], oldest_available_revision: null, more: false } },
      error: null,
    };
    const wrapper = mountPanel(null);
    await flushPromises();

    expect(wrapper.find('.webui-history__empty').exists()).toBe(true);
    expect(wrapper.findAll('.webui-history__row')).toHaveLength(0);
  });

  it('surfaces backend errors inline instead of crashing', async () => {
    nextQueryResult = { data: null, error: { message: 'HISTORY_LIST_FAILED: etcd offline' } };
    const wrapper = mountPanel(null);
    await flushPromises();

    const error = wrapper.find('.webui-history__error');
    expect(error.exists()).toBe(true);
    expect(error.text()).toContain('HISTORY_LIST_FAILED');
  });

  it('emits select-revision with the revision number when View is clicked', async () => {
    const wrapper = mountPanel(99); // not in list — every row's View must be enabled
    await flushPromises();

    const viewButtons = wrapper
      .findAll('button')
      .filter((b) => b.text() === 'View');
    await viewButtons[0].trigger('click'); // first row = revision 12

    expect(wrapper.emitted('select-revision')).toBeTruthy();
    expect(wrapper.emitted('select-revision')![0]).toEqual([12]);
  });

  it('emits request-diff with against="current" when Diff vs current is clicked', async () => {
    const wrapper = mountPanel(99);
    await flushPromises();

    const btn = wrapper.findAll('button').filter((b) => b.text() === 'Diff vs current')[0];
    await btn.trigger('click');

    expect(wrapper.emitted('request-diff')![0]).toEqual([12, 'current']);
  });

  it('disables Diff vs prev on the oldest available revision', async () => {
    const wrapper = mountPanel(99);
    await flushPromises();

    const rows = wrapper.findAll('.webui-history__row');
    const oldestRowButtons = rows[2]
      .findAll('button')
      .filter((b) => b.text() === 'Diff vs prev');
    expect(oldestRowButtons[0].attributes('disabled')).toBeDefined();
  });

  it('disables Rollback on the row matching currentRevision', async () => {
    const wrapper = mountPanel(12);
    await flushPromises();

    const rows = wrapper.findAll('.webui-history__row');
    const rollbackOnActive = rows[0]
      .findAll('button')
      .filter((b) => b.text() === 'Rollback')[0];
    expect(rollbackOnActive.attributes('disabled')).toBeDefined();
  });

  it('emits request-rollback with the chosen revision', async () => {
    const wrapper = mountPanel(99); // active is not in list → every Rollback enabled
    await flushPromises();

    const btn = wrapper.findAll('button').filter((b) => b.text() === 'Rollback')[0];
    await btn.trigger('click');

    expect(wrapper.emitted('request-rollback')![0]).toEqual([12]);
  });

  it('exposes refresh() so the parent can re-fetch after a commit', async () => {
    const wrapper = mountPanel();
    await flushPromises();
    expect(queryMock).toHaveBeenCalledTimes(1);

    const exposed = wrapper.vm as unknown as { refresh: () => Promise<void> };
    await exposed.refresh();
    await flushPromises();

    expect(queryMock).toHaveBeenCalledTimes(2);
  });
});
