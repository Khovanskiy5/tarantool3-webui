/**
 * vue-i18n provider bootstrap.
 *
 * The i18n instance is created in `@/shared/i18n` because that is its
 * domain-agnostic home. This provider only installs it on the Vue app
 * and sets the initial <html lang> attribute.
 */

import type { App } from 'vue';

import { i18n } from '@/shared/i18n';

export const installI18n = (app: App): void => {
  app.use(i18n);
  if (typeof document !== 'undefined') {
    document.documentElement.setAttribute('lang', i18n.global.locale.value as string);
  }
};
