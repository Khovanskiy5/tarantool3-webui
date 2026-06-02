/**
 * Vitest coverage for the bootstrap wizard's admin-credentials Card.
 *
 * The component talks to urql via the singleton client; we mock it
 * and capture variables passed into mutation()/query() to assert the
 * exact admin_credentials payload that goes over the wire. The most
 * likely regression is "Apply enabled with an invalid password" — a
 * tiny v-model bug that would let the wizard ship a YAML the backend
 * happily renders with hardcoded dev fixtures and a weak admin.
 *
 * We do NOT exercise visual rendering — PrimeVue components are
 * replaced with thin stubs that preserve only the v-model surface
 * the form drives.
 */

import { mount, flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import Bootstrap from './Bootstrap.vue';

interface CapturedVars {
  t?: string;
  n?: string;
  c?: { login: string; password: string } | null;
}
interface CapturedCall {
  op: 'query' | 'mutation';
  variables: CapturedVars;
}

let captured: CapturedCall[] = [];

// Status query response. Tests flip this between {needed=true} and
// {needed=false} to exercise both surfaces.
let statusResponse: { needed: boolean } = { needed: true };

// Most recent init mutation result the mock should return.
let nextInitResult: {
  data: { bootstrapInitialize: Record<string, unknown> } | null;
  error: { message: string } | null;
} = {
  data: {
    bootstrapInitialize: {
      ok: true,
      revision: 7,
      reloaded_count: 3,
      reload_failures: [],
      etcd_used: true,
      dry_run: false,
      error_code: null,
      message: null,
      yaml: 'rendered',
    },
  },
  error: null,
};

const queryMock = vi.fn((doc: string, variables: CapturedVars) => {
  captured.push({ op: 'query', variables });
  const isBootstrap = doc.includes('bootstrapStatus');
  return {
    toPromise: () =>
      Promise.resolve(
        isBootstrap
          ? {
              data: {
                bootstrapStatus: {
                  needed: statusResponse.needed,
                  reason: 'no cluster config detected',
                  source: 'etcd',
                  etcd_available: true,
                  etcd_error: null,
                },
                bootstrapTemplates: {
                  templates: [
                    {
                      name: 'replicaset-3',
                      title: '3-instance replicaset',
                      description: 'baseline',
                    },
                  ],
                },
              },
              error: null,
            }
          : {
              data: { bootstrapRender: { yaml: 'preview', error: null } },
              error: null,
            },
      ),
  };
});

const mutationMock = vi.fn((_doc: string, variables: CapturedVars) => {
  captured.push({ op: 'mutation', variables });
  return { toPromise: () => Promise.resolve(nextInitResult) };
});

vi.mock('@/shared/api/graphql', () => ({
  getClient: () => ({ query: queryMock, mutation: mutationMock }),
}));

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

// Thin stubs for every PrimeVue component the wizard mounts.
const InputStub = {
  name: 'InputText',
  props: ['modelValue', 'invalid'],
  emits: ['update:modelValue'],
  template:
    '<input :class="{ invalid }" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};
const PasswordStub = {
  name: 'Password',
  props: ['modelValue', 'invalid', 'feedback', 'toggleMask'],
  emits: ['update:modelValue'],
  template:
    '<input :class="{ invalid }" type="password" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};
const ButtonStub = {
  name: 'Button',
  props: ['label', 'disabled', 'loading'],
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};
const DropdownStub = {
  name: 'Dropdown',
  props: ['modelValue', 'options'],
  emits: ['update:modelValue'],
  template: '<select :value="modelValue"></select>',
};
const CardStub = {
  name: 'Card',
  template:
    '<div class="card"><div class="card-title"><slot name="title" /></div><div class="card-content"><slot name="content" /></div></div>',
};
const MessageStub = {
  name: 'Message',
  props: ['severity', 'closable'],
  template: '<div :class="`message-${severity}`"><slot /></div>',
};
const YamlEditorStub = {
  name: 'YamlEditor',
  props: ['modelValue', 'readonly', 'height'],
  template: '<pre class="yaml">{{ modelValue }}</pre>',
};

function mountBootstrap() {
  return mount(Bootstrap, {
    global: {
      stubs: {
        InputText: InputStub,
        Password: PasswordStub,
        Button: ButtonStub,
        Dropdown: DropdownStub,
        Card: CardStub,
        Message: MessageStub,
        YamlEditor: YamlEditorStub,
      },
    },
  });
}

async function settleInitialQueries(
  wrapper: ReturnType<typeof mountBootstrap>,
) {
  // onMounted fires `load` then `renderPreview` — both return promises.
  await flushPromises();
  await flushPromises();
  await wrapper.vm.$nextTick();
}

describe('Bootstrap wizard — admin credentials Card', () => {
  beforeEach(() => {
    captured = [];
    statusResponse = { needed: true };
  });
  afterEach(() => {
    queryMock.mockClear();
    mutationMock.mockClear();
  });

  it('Apply is disabled while password is empty', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const buttons = w.findAll('button');
    const apply = buttons.find((b) => b.text().includes('Apply'));
    expect(apply).toBeTruthy();
    expect(apply!.attributes('disabled')).toBeDefined();
  });

  it('Apply is disabled when password is too short', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    // 1st = clusterName, 2nd = adminLogin, 3rd = adminPassword, 4th = confirm
    const adminLogin = inputs[1];
    const adminPwd = inputs[2];
    const adminPwdConfirm = inputs[3];
    await adminLogin.setValue('admin');
    await adminPwd.setValue('Short1');
    await adminPwdConfirm.setValue('Short1');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    expect(apply!.attributes('disabled')).toBeDefined();
  });

  it('Apply is disabled when password has no digits', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    await inputs[1].setValue('admin');
    await inputs[2].setValue('LettersOnlyHere');
    await inputs[3].setValue('LettersOnlyHere');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    expect(apply!.attributes('disabled')).toBeDefined();
  });

  it('Apply is disabled when passwords do not match', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    await inputs[1].setValue('admin');
    await inputs[2].setValue('OperatorChose2026');
    await inputs[3].setValue('Different2026Pass');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    expect(apply!.attributes('disabled')).toBeDefined();
  });

  it('Apply is disabled when login has invalid charset', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    await inputs[1].setValue('My-Admin'); // uppercase + dash → reject
    await inputs[2].setValue('OperatorChose2026');
    await inputs[3].setValue('OperatorChose2026');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    expect(apply!.attributes('disabled')).toBeDefined();
  });

  it('Apply becomes enabled when credentials are valid', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    await inputs[1].setValue('admin');
    await inputs[2].setValue('OperatorChose2026');
    await inputs[3].setValue('OperatorChose2026');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    expect(apply!.attributes('disabled')).toBeUndefined();
  });

  it('mutation receives the exact admin_credentials payload', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    const inputs = w.findAll('input');
    await inputs[1].setValue('opadmin');
    await inputs[2].setValue('OperatorChose2026');
    await inputs[3].setValue('OperatorChose2026');
    await flushPromises();
    const apply = w.findAll('button').find((b) => b.text().includes('Apply'));
    await apply!.trigger('click');
    await flushPromises();
    const calls = captured.filter((c) => c.op === 'mutation');
    expect(calls.length).toBe(1);
    expect(calls[0].variables.c).toEqual({
      login: 'opadmin',
      password: 'OperatorChose2026',
    });
  });

  it('renderPreview forwards admin_credentials when valid', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    captured = [];
    const inputs = w.findAll('input');
    await inputs[1].setValue('opadmin');
    await inputs[2].setValue('OperatorChose2026');
    await inputs[3].setValue('OperatorChose2026');
    await flushPromises();
    // The render-on-watch fires when login/password change. Last
    // captured query should carry the admin_credentials block.
    const renderCalls = captured.filter((c) => c.op === 'query');
    const last = renderCalls[renderCalls.length - 1];
    expect(last.variables.c).toEqual({
      login: 'opadmin',
      password: 'OperatorChose2026',
    });
  });

  it('renderPreview sends null credentials before they are valid', async () => {
    const w = mountBootstrap();
    await settleInitialQueries(w);
    captured = [];
    const inputs = w.findAll('input');
    await inputs[1].setValue('admin');
    await inputs[2].setValue('Short1');
    await flushPromises();
    const renderCalls = captured.filter((c) => c.op === 'query');
    // The most recent render call has invalid credentials → null.
    const last = renderCalls[renderCalls.length - 1];
    expect(last.variables.c).toBeNull();
  });
});
