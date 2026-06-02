/**
 * ESLint flat config for the WebUI frontend.
 *
 * Migrated from .eslintrc.cjs when ESLint 9+ made flat config the
 * only supported format. The single source of truth for
 * Feature-Sliced Design boundaries is still `eslint-plugin-boundaries`;
 * the configuration below mirrors the FSD layer hierarchy
 * `app → pages → widgets → features → entities → shared` and rejects
 * any import that violates that direction or that reaches into a slice
 * without going through its `index.ts` public API.
 */

import { defineConfigWithVueTs, vueTsConfigs } from '@vue/eslint-config-typescript';
import pluginVue from 'eslint-plugin-vue';
import pluginBoundaries from 'eslint-plugin-boundaries';
import globals from 'globals';

export default defineConfigWithVueTs(
  // Project-wide ignores (previously .eslintignore).
  {
    ignores: [
      'node_modules/**',
      'dist/**',
      'storybook-static/**',
      'coverage/**',
      'playwright-report/**',
      'test-results/**',
      'src/shared/api/__generated/**',
      '**/*.config.cjs',
    ],
  },

  // Vue 3 recommended ruleset (flat-config flavour). In
  // eslint-plugin-vue 10 the Vue-3 path is the default; only Vue-2
  // configs carry an explicit `vue2-` prefix.
  ...pluginVue.configs['flat/recommended'],

  // TypeScript + Vue integration. `recommended` mirrors what
  // @vue/eslint-config-typescript wired through @typescript-eslint.
  vueTsConfigs.recommended,

  // Project-wide language options. Browser + node globals because
  // tests, tooling, and runtime app code all share this config.
  {
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.node,
        ...globals.es2022,
      },
    },
  },

  // FSD boundaries + project-specific rules.
  {
    plugins: {
      boundaries: pluginBoundaries,
    },
    settings: {
      'boundaries/include': ['src/**/*'],
      'boundaries/elements': [
        { type: 'app', pattern: 'src/app/*', mode: 'folder' },
        { type: 'pages', pattern: 'src/pages/*', mode: 'folder' },
        { type: 'widgets', pattern: 'src/widgets/*', mode: 'folder' },
        { type: 'features', pattern: 'src/features/*', mode: 'folder' },
        { type: 'entities', pattern: 'src/entities/*', mode: 'folder' },
        { type: 'shared', pattern: 'src/shared/*', mode: 'folder' },
      ],
    },
    rules: {
      // FSD layer hierarchy. A higher layer may import any lower layer;
      // same-layer imports are forbidden (cross-slice coupling), with the
      // single exception of `shared`, which is allowed to compose itself
      // because that is the only layer with truly generic primitives.
      'boundaries/element-types': [
        2,
        {
          default: 'disallow',
          rules: [
            { from: 'app', allow: ['pages', 'widgets', 'features', 'entities', 'shared'] },
            { from: 'pages', allow: ['widgets', 'features', 'entities', 'shared'] },
            { from: 'widgets', allow: ['features', 'entities', 'shared'] },
            { from: 'features', allow: ['entities', 'shared'] },
            { from: 'entities', allow: ['shared'] },
            { from: 'shared', allow: ['shared'] },
          ],
        },
      ],
      // Imports must go through the slice index.ts; reaching directly
      // into `model/`, `ui/` etc. of another slice defeats encapsulation.
      'boundaries/no-private': [2, { allowUncles: false }],
      // Untyped any is permitted only as a deliberate escape hatch with
      // an explanatory comment; the rule keeps it from spreading silently.
      '@typescript-eslint/no-explicit-any': 'warn',
      // Vue templates compile away unused props; this rule flags them.
      'vue/no-unused-properties': ['warn', { groups: ['props'] }],
      // Match the project naming convention: PascalCase for components.
      'vue/component-name-in-template-casing': ['error', 'PascalCase'],
      // The multi-word rule is relaxed: under FSD, slice folder names
      // disambiguate components, so `Sidebar.vue` inside `widgets/sidebar/`
      // is unambiguous despite the rule's preference for `AppSidebar`.
      'vue/multi-word-component-names': 'off',
      // Whitespace/attribute formatting is owned by prettier, not eslint.
      // The vue/html-* rules below collide with prettier's template
      // formatter; running eslint --fix and prettier --write back-and-
      // forth would otherwise loop. Prettier wins for everything that
      // is purely cosmetic; eslint keeps the semantic checks.
      'vue/singleline-html-element-content-newline': 'off',
      'vue/max-attributes-per-line': 'off',
      'vue/html-closing-bracket-newline': 'off',
      'vue/html-indent': 'off',
      'vue/multiline-html-element-content-newline': 'off',
      'vue/html-self-closing': 'off',
      'vue/html-quotes': 'off',
    },
  },

  // CLI scripts and config files: turn off the FSD rules — they only
  // apply to src/ production code.
  {
    files: ['tools/**/*', 'vite.config.ts', 'vitest.config.ts', '*.cjs', 'eslint.config.js'],
    rules: {
      'boundaries/element-types': 'off',
      'boundaries/no-private': 'off',
    },
  },

  // Storybook config + co-located *.stories.ts files. They sit alongside
  // the components they document and therefore must be allowed to import
  // from any layer — the FSD rules apply to production code, not to
  // documentation harnesses.
  {
    files: ['.storybook/**/*', 'src/**/*.stories.ts'],
    rules: {
      'boundaries/element-types': 'off',
      'boundaries/no-private': 'off',
    },
  },
);
