/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue';
  // The triple-`any` mirrors Vue's own `*.vue` template — props,
  // setup state, and instance type are all opaque from the shim's
  // point of view; vue-tsc narrows them via the SFC compiler.
  /* eslint-disable @typescript-eslint/no-explicit-any */
  const component: DefineComponent<any, any, any>;
  /* eslint-enable @typescript-eslint/no-explicit-any */
  export default component;
}

// monaco-editor 0.55 ships subpath `.contribution` modules as
// side-effect-only entries. Their .d.ts files exist but TypeScript's
// bundler resolver under "exports": { "./*": "./*" } is stricter in
// TS 6 and skips them. Declare each one we import as an empty module
// so vue-tsc is happy; Vite resolves the actual files normally.
declare module 'monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution' {}
declare module 'monaco-editor/esm/vs/basic-languages/sql/sql.contribution' {}

interface ImportMetaEnv {
  readonly VITE_APP_VERSION?: string;
  readonly VITE_APP_BASE_URL?: string;
  readonly VITE_API_BASE_URL?: string;
  readonly VITE_BACKEND_URL?: string;
  readonly VITE_LOG_LEVEL?: 'debug' | 'info' | 'warn' | 'error';
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
