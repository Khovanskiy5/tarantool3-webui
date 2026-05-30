/**
 * Pinia bootstrap.
 *
 * One global Pinia instance. Stores live in entity slices (or feature
 * slices when they own transient interaction state) and register
 * themselves on first `defineStore` call.
 */

import { createPinia, type Pinia } from 'pinia';

export const createPiniaProvider = (): Pinia => createPinia();
