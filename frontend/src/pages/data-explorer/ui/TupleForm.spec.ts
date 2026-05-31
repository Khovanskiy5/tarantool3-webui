/**
 * Vitest coverage for TupleForm — coercion + create/edit behaviour.
 *
 * The component talks to urql via the singleton client; we mock it
 * and capture the variables passed to mutation() so the test asserts
 * what actually goes over the wire (the most likely regression
 * surface — wrong coercion of nullable / numeric / map fields silently
 * corrupts data).
 */

import { mount, flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import TupleForm from './TupleForm.vue';

interface CapturedCall {
  variables: { space: string; fields: unknown[] };
}

let captured: CapturedCall[] = [];
let nextMutationResult: { data: unknown; error: { message: string } | null } = {
  data: { tupleInsert: { ok: true } },
  error: null,
};

const mutationMock = vi.fn((_doc: unknown, variables: { space: string; fields: unknown[] }) => {
  captured.push({ variables });
  return { toPromise: () => Promise.resolve(nextMutationResult) };
});

vi.mock('@/shared/api/graphql', () => ({
  getClient: () => ({ query: vi.fn(), mutation: mutationMock }),
}));

// Each PrimeVue component is replaced with a thin stub that
// preserves the v-model / props / events surface we exercise. We
// do not care about visual rendering here — only that the form
// pipes user input through to the GraphQL variables correctly.
const DialogStub = {
  name: 'Dialog',
  props: ['visible', 'modal', 'header'],
  emits: ['update:visible'],
  template: `
    <div v-if="visible" class="dialog-stub">
      <slot />
      <div class="dialog-footer"><slot name="footer" /></div>
    </div>
  `,
};
const ButtonStub = {
  name: 'Button',
  props: ['label', 'icon', 'disabled', 'loading', 'severity', 'text'],
  emits: ['click'],
  template: '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};
const InputTextStub = {
  name: 'InputText',
  props: ['modelValue', 'disabled'],
  emits: ['update:modelValue'],
  template: '<input :disabled="disabled" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};
const TextareaStub = {
  name: 'Textarea',
  props: ['modelValue', 'disabled'],
  emits: ['update:modelValue'],
  template: '<textarea :disabled="disabled" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};
const CheckboxStub = {
  name: 'Checkbox',
  props: ['modelValue', 'binary'],
  emits: ['update:modelValue'],
  template: '<input type="checkbox" :checked="modelValue" @change="$emit(\'update:modelValue\', $event.target.checked)" />',
};
const MessageStub = { name: 'Message', template: '<div><slot /></div>' };

const baseSpace = {
  id: 519,
  name: 'dx_test',
  format: [
    { name: 'id', type: 'unsigned', is_nullable: false, collation: null },
    { name: 'tag', type: 'string', is_nullable: true, collation: null },
    { name: 'meta', type: 'map', is_nullable: true, collation: null },
  ],
  indexes: [{ id: 0, parts: ['id'] }],
};

function mountForm(overrides: Record<string, unknown> = {}) {
  return mount(TupleForm, {
    props: {
      visible: true,
      space: baseSpace,
      mode: 'create',
      initialFields: null,
      ...overrides,
    } as Record<string, unknown>,
    global: {
      stubs: {
        Dialog: DialogStub,
        Button: ButtonStub,
        InputText: InputTextStub,
        Textarea: TextareaStub,
        Checkbox: CheckboxStub,
        Message: MessageStub,
      },
    },
  });
}

beforeEach(() => {
  captured = [];
  nextMutationResult = { data: { tupleInsert: { ok: true } }, error: null };
});

afterEach(() => {
  mutationMock.mockClear();
});

describe('TupleForm', () => {
  it('creates rows from space.format in CREATE mode with editable inputs', async () => {
    const wrapper = mountForm();
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    const textareas = wrapper.findAll('textarea');
    // 3 fields: id (input), tag (input), meta:map (textarea).
    // The map field renders as a textarea so the operator can type
    // multi-line JSON.
    expect(inputs.length).toBe(2);
    expect(textareas.length).toBe(1);
    inputs.forEach((i) => {
      expect((i.element as HTMLInputElement).disabled).toBe(false);
    });
    expect((textareas[0].element as HTMLTextAreaElement).disabled).toBe(false);
  });

  it('coerces numeric fields to Number on submit', async () => {
    const wrapper = mountForm();
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    await inputs[0].setValue('42');
    await inputs[1].setValue('hello');
    const insertBtn = wrapper.findAll('button').find((b) => b.text() === 'Insert');
    expect(insertBtn).toBeDefined();
    await insertBtn!.trigger('click');
    await flushPromises();
    expect(captured.length).toBe(1);
    expect(captured[0].variables.space).toBe('dx_test');
    // id is 'unsigned' → coerced to 42 (Number), not "42" (String)
    expect(captured[0].variables.fields[0]).toBe(42);
    // tag is 'string' → passes through as-is
    expect(captured[0].variables.fields[1]).toBe('hello');
  });

  it('parses map fields as JSON on submit', async () => {
    const wrapper = mountForm();
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    const textareas = wrapper.findAll('textarea');
    await inputs[0].setValue('7');
    await inputs[1].setValue('any');
    expect(textareas.length).toBeGreaterThanOrEqual(1);
    await textareas[0].setValue('{"k": 1, "n": "v"}');
    const insertBtn = wrapper.findAll('button').find((b) => b.text() === 'Insert');
    await insertBtn!.trigger('click');
    await flushPromises();
    expect(captured.length).toBe(1);
    expect(captured[0].variables.fields[2]).toEqual({ k: 1, n: 'v' });
  });

  it('emits saved when the mutation returns ok: true', async () => {
    const wrapper = mountForm();
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    await inputs[0].setValue('1');
    const insertBtn = wrapper.findAll('button').find((b) => b.text() === 'Insert');
    await insertBtn!.trigger('click');
    await flushPromises();
    expect(wrapper.emitted('saved')).toBeTruthy();
    expect(wrapper.emitted('saved')!.length).toBe(1);
  });

  it('surfaces graphql errors without emitting saved', async () => {
    nextMutationResult = {
      data: null,
      error: { message: 'FORBIDDEN: insert on system space _user is blocked.' },
    };
    const wrapper = mountForm();
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    await inputs[0].setValue('1');
    const insertBtn = wrapper.findAll('button').find((b) => b.text() === 'Insert');
    await insertBtn!.trigger('click');
    await flushPromises();
    expect(wrapper.emitted('saved')).toBeFalsy();
    // The Message stub renders the text — assert it lands in DOM.
    expect(wrapper.text()).toContain('FORBIDDEN');
  });

  it('initialises EDIT mode with the existing values and the null toggle off', async () => {
    const wrapper = mountForm({
      mode: 'edit',
      initialFields: [99, 'preset', { existing: true }],
    });
    await flushPromises();
    const inputs = wrapper.findAll('input:not([type=checkbox])');
    expect((inputs[0].element as HTMLInputElement).value).toBe('99');
    expect((inputs[1].element as HTMLInputElement).value).toBe('preset');
    // Number 99 is editable; the null checkbox stays off.
    const checkboxes = wrapper.findAll('input[type=checkbox]');
    checkboxes.forEach((c) => {
      expect((c.element as HTMLInputElement).checked).toBe(false);
    });
  });

  it('sets is_null on a nullable field whose stored value is null (edit mode)', async () => {
    const wrapper = mountForm({
      mode: 'edit',
      initialFields: [1, null, null],
    });
    await flushPromises();
    const checkboxes = wrapper.findAll('input[type=checkbox]');
    // The 1st nullable field (tag) starts with `is_null = true`,
    // and so does the 2nd (meta). The id field is non-nullable so
    // its row has no checkbox at all — only two boxes total.
    expect(checkboxes.length).toBe(2);
    expect((checkboxes[0].element as HTMLInputElement).checked).toBe(true);
    expect((checkboxes[1].element as HTMLInputElement).checked).toBe(true);
  });
});
