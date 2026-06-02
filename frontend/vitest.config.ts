import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vitest/config';
import vue from '@vitejs/plugin-vue';

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  plugins: [vue()],
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
  test: {
    environment: 'happy-dom',
    globals: false,
    include: ['src/**/*.{spec,test}.{ts,vue}', 'tests/unit/**/*.{spec,test}.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      reportsDirectory: '../coverage/ts',
    },
  },
});
