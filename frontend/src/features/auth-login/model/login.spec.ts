/**
 * Unit tests for the auth-login store error mapping.
 */

import { describe, expect, it, beforeEach } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

import { useLoginStore } from './login';

describe('useLoginStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('starts with no error and not pending', () => {
    const store = useLoginStore();
    expect(store.pending).toBe(false);
    expect(store.error).toBeNull();
  });

  it('reset() clears the error', () => {
    const store = useLoginStore();
    store.$patch({ error: { code: 'LOGIN_FAILED', message: 'x' } });
    store.reset();
    expect(store.error).toBeNull();
  });
});
