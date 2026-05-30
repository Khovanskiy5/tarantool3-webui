/**
 * ESLint configuration for the WebUI frontend.
 *
 * The single source of truth for Feature-Sliced Design boundaries is
 * `eslint-plugin-boundaries`. The configuration below mirrors the FSD
 * layer hierarchy `app → pages → widgets → features → entities → shared`
 * and rejects any import that violates that direction or that reaches
 * into a slice without going through its `index.ts` public API.
 */
module.exports = {
  root: true,
  env: {
    browser: true,
    es2022: true,
    node: true,
  },
  extends: [
    'plugin:vue/vue3-recommended',
    '@vue/eslint-config-typescript',
  ],
  parserOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
  },
  plugins: ['boundaries'],
  settings: {
    'boundaries/include': ['src/**/*'],
    'boundaries/elements': [
      { type: 'app',      pattern: 'src/app/*',      mode: 'folder' },
      { type: 'pages',    pattern: 'src/pages/*',    mode: 'folder' },
      { type: 'widgets',  pattern: 'src/widgets/*',  mode: 'folder' },
      { type: 'features', pattern: 'src/features/*', mode: 'folder' },
      { type: 'entities', pattern: 'src/entities/*', mode: 'folder' },
      { type: 'shared',   pattern: 'src/shared/*',   mode: 'folder' },
    ],
  },
  rules: {
    // FSD layer hierarchy. A higher layer may import any lower layer;
    // same-layer imports are forbidden (cross-slice coupling), with the
    // single exception of `shared`, which is allowed to compose itself
    // because that is the only layer with truly generic primitives.
    'boundaries/element-types': [2, {
      default: 'disallow',
      rules: [
        { from: 'app',      allow: ['pages', 'widgets', 'features', 'entities', 'shared'] },
        { from: 'pages',    allow: ['widgets', 'features', 'entities', 'shared'] },
        { from: 'widgets',  allow: ['features', 'entities', 'shared'] },
        { from: 'features', allow: ['entities', 'shared'] },
        { from: 'entities', allow: ['shared'] },
        { from: 'shared',   allow: ['shared'] },
      ],
    }],
    // Imports must go through the slice index.ts; reaching directly
    // into `model/`, `ui/` etc. of another slice defeats encapsulation.
    'boundaries/no-private': [2, { allowUncles: false }],
    // Untyped any is permitted only as a deliberate escape hatch with
    // an explanatory comment; the rule keeps it from spreading silently.
    '@typescript-eslint/no-explicit-any': 'warn',
    // Vue templates compile away unused props; this rule flags them.
    'vue/no-unused-properties': ['warn', { groups: ['props'] }],
    // Match the project naming convention from `.ai-factory/rules/base.md`.
    'vue/component-name-in-template-casing': ['error', 'PascalCase'],
    // The multi-word rule is relaxed: under FSD, slice folder names
    // disambiguate components, so `Sidebar.vue` inside `widgets/sidebar/`
    // is unambiguous despite the rule's preference for `AppSidebar`.
    'vue/multi-word-component-names': 'off',
    // Whitespace/attribute formatting is owned by prettier, not eslint.
    'vue/singleline-html-element-content-newline': 'off',
    'vue/max-attributes-per-line': 'off',
  },
  overrides: [
    {
      files: ['tools/**/*', 'vite.config.ts', 'vitest.config.ts', '*.cjs'],
      rules: {
        'boundaries/element-types': 'off',
        'boundaries/no-private': 'off',
      },
    },
    {
      // Storybook config + co-located *.stories.ts files. They sit
      // alongside the components they document and therefore must be
      // allowed to import from any layer — the FSD rules apply to
      // production code, not to documentation harnesses.
      files: ['.storybook/**/*', 'src/**/*.stories.ts'],
      rules: {
        'boundaries/element-types': 'off',
        'boundaries/no-private': 'off',
      },
    },
  ],
};
