import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { compression } from 'vite-plugin-compression2';

// Monaco web workers: the legacy `vite-plugin-monaco-editor` is
// incompatible with Vite 5+. The supported pattern is the native Vite
// `?worker` query, used at the point of import in the config editor
// (Task 38) and console (Task 44) pages:
//
//   import EditorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
//   self.MonacoEnvironment = { getWorker: () => new EditorWorker() };
//
// This keeps the worker bundle code-split by Vite and removes the need
// for a custom plugin in this file.

// resolve() helper keeps imports concise and matches tsconfig paths.
// Aliases MUST stay byte-for-byte equivalent to compilerOptions.paths in
// tsconfig.json; otherwise vite and tsc disagree on what `@/widgets/foo`
// refers to. The pre-commit check `bun run check-fsd` verifies this.
const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig(({ mode }) => ({
  // base: './' keeps relative asset paths so the same bundle works behind
  // any base URL (HAProxy, sub-path deploys, ingress prefixes).
  base: './',

  resolve: {
    alias: {
      '@/app': r('./src/app'),
      '@/pages': r('./src/pages'),
      '@/widgets': r('./src/widgets'),
      '@/features': r('./src/features'),
      '@/entities': r('./src/entities'),
      '@/shared': r('./src/shared'),
    },
  },

  plugins: [
    vue(),
    // Pre-compressed assets reduce edge HTTP cost. A single compression2
    // invocation can emit multiple algorithms; calling the plugin twice
    // makes it race on the same assets and corrupt rollup's output set.
    compression({
      algorithms: ['brotliCompress', 'gzip'],
      exclude: [/\.(br|gz)$/],
    }),
  ],

  build: {
    target: 'es2022',
    cssCodeSplit: true,
    // .map files are emitted but not referenced from the HTML so they
    // can be uploaded to error-tracking services without leaking source
    // paths to public users.
    sourcemap: 'hidden',
    // Monaco editor is gated behind a dynamic import (Schema, Console,
    // ConfigEditor) and lands in its own ~3.3 MB `monaco-editor` chunk
    // — by design, since splitting Monaco further yields tiny chunks
    // that re-trigger the same warning. The threshold below is set
    // above Monaco's natural size; any new chunk approaching 4 MB is
    // a real regression worth investigating.
    chunkSizeWarningLimit: 4096,
    rollupOptions: {
      output: {
        // manualChunks groups dependencies into named lazy chunks. Vite
        // 8 / Rollup 4 dropped the object form; the function form maps
        // any module under node_modules/<pkg> to a named chunk. Tweaks
        // here require re-checking the bundle-size budget (see plan,
        // Performance budgets contract).
        manualChunks(id) {
          if (!id.includes('node_modules')) return undefined;
          // Monaco is gated behind dynamic import in Task 38 so its
          // bundle stays out of the initial app shell.
          if (id.includes('/node_modules/monaco-editor/')) return 'monaco-editor';
          if (
            id.includes('/node_modules/vue/') ||
            id.includes('/node_modules/vue-router/') ||
            id.includes('/node_modules/pinia/') ||
            id.includes('/node_modules/vue-i18n/') ||
            id.includes('/node_modules/@vue/')
          ) {
            return 'vendor-vue';
          }
          if (
            id.includes('/node_modules/@urql/') ||
            id.includes('/node_modules/graphql/') ||
            id.includes('/node_modules/wonka/')
          ) {
            return 'vendor-urql';
          }
          if (id.includes('/node_modules/primevue/') || id.includes('/node_modules/@primevue/')) {
            return 'vendor-primevue';
          }
          if (id.includes('/node_modules/dayjs/') || id.includes('/node_modules/ajv/')) {
            return 'vendor-misc';
          }
          return undefined;
        },
      },
    },
  },

  server: {
    port: 5173,
    strictPort: true,
    // Proxy backend APIs to a single instance during HMR. In docker-
    // compose.dev.yml the dev frontend container points at tt-1 by name;
    // local-host development can override the target via env.
    proxy: {
      '/admin/api': {
        target: process.env.VITE_BACKEND_URL || 'http://localhost:8081',
        changeOrigin: true,
      },
      '/api': {
        target: process.env.VITE_BACKEND_URL || 'http://localhost:8081',
        changeOrigin: true,
      },
      '/ws': {
        target: process.env.VITE_BACKEND_URL || 'http://localhost:8081',
        changeOrigin: true,
        ws: true,
      },
    },
  },

  // Bun-specific note: Vite runs unchanged under Bun thanks to Bun's
  // Node API parity. No bun-specific configuration is required here.
  define: {
    __DEV__: JSON.stringify(mode !== 'production'),
  },
}));
