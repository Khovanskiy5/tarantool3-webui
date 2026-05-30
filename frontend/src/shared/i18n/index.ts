/**
 * vue-i18n instance and locale registry.
 *
 * The instance lives in the `shared` layer because it has no domain
 * knowledge. Bootstrap (Vue plugin install) happens in
 * `@/app/providers/i18n` to keep this module side-effect free.
 *
 * Supported locales at first release: ru (default) and en.
 * Adding a new locale is a JSON-only change — register the messages
 * here and add the switcher option in the top-bar widget.
 *
 * Missing-key strategy:
 *   - dev: console warning surfaces typos early
 *   - prod: silent fallback to English; the missing key is reported via
 *           a future metric `webui_i18n_missing_keys_total` (Task 42a)
 */

import { createI18n } from 'vue-i18n';

import en from './locales/en.json';
import ru from './locales/ru.json';

export type Locale = 'ru' | 'en';

export const SUPPORTED_LOCALES: Locale[] = ['ru', 'en'];
export const DEFAULT_LOCALE: Locale = 'ru';

const STORAGE_KEY = 'webui:locale';

const detectInitialLocale = (): Locale => {
  // Stored preference wins over browser language so explicit choice
  // survives logout / cleared cookies.
  if (typeof localStorage !== 'undefined') {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === 'ru' || stored === 'en') return stored;
  }
  if (typeof navigator !== 'undefined' && navigator.language) {
    const base = navigator.language.toLowerCase().split('-')[0];
    if (base === 'ru') return 'ru';
    if (base === 'en') return 'en';
  }
  return DEFAULT_LOCALE;
};

export const i18n = createI18n({
  legacy: false,
  globalInjection: true,
  locale: detectInitialLocale(),
  fallbackLocale: 'en',
  missingWarn: import.meta.env.DEV,
  fallbackWarn: import.meta.env.DEV,
  messages: { ru, en },
  // Plurals use vue-i18n built-in pipe syntax: "no | one | many".
});

export const setLocale = (locale: Locale): void => {
  if (!SUPPORTED_LOCALES.includes(locale)) return;
  i18n.global.locale.value = locale;
  if (typeof document !== 'undefined') {
    document.documentElement.setAttribute('lang', locale);
  }
  if (typeof localStorage !== 'undefined') {
    localStorage.setItem(STORAGE_KEY, locale);
  }
};
