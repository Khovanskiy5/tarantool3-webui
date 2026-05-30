/**
 * Storybook 8 configuration for the WebUI frontend.
 *
 * Stories are co-located with the components they document
 * (`<Component>.stories.ts` next to `<Component>.vue`). Storybook
 * uses the same Vite pipeline as the app — including the FSD path
 * aliases — so stories import from `@/shared`, `@/widgets`, etc.
 * exactly like production code.
 */

import type { StorybookConfig } from '@storybook/vue3-vite';
import { fileURLToPath, URL } from 'node:url';
import { mergeConfig } from 'vite';

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

const config: StorybookConfig = {
  framework: {
    name: '@storybook/vue3-vite',
    options: {},
  },

  // shared/ui/* covers every domain-free primitive; widgets host
  // larger composite components. New layers (entities, features,
  // pages) are intentionally NOT scanned — stories belong to UI
  // primitives, not to business slices.
  stories: [
    '../src/shared/ui/**/*.stories.@(ts|js)',
    '../src/widgets/**/*.stories.@(ts|js)',
  ],

  addons: [
    '@storybook/addon-essentials',
    '@storybook/addon-a11y',
    '@storybook/addon-themes',
    '@storybook/addon-interactions',
    '@storybook/addon-viewport',
  ],

  docs: {
    // Auto-generate a `Docs` tab per story file from JSDoc and
    // argTypes. Component-specific MDX can opt out by adding a
    // `parameters.docs.disable = true` to the story file.
    autodocs: 'tag',
  },

  typescript: {
    // Storybook 8 owns the props-table generation for Vue via
    // vue-docgen-api regardless of this flag. We only opt out of the
    // separate type-checking pass — `bun run type-check` already runs
    // `vue-tsc` over the whole project, so duplicating that work
    // inside Storybook is wasted CI time.
    check: false,
    skipCompiler: false,
  },

  viteFinal: async (vite) => {
    // Re-apply the FSD aliases from vite.config.ts. Keeping them
    // in sync with `tsconfig.json` paths and the app Vite config is
    // mandatory — drift breaks `bun run check-fsd`.
    return mergeConfig(vite, {
      resolve: {
        alias: {
          '@/app': r('../src/app'),
          '@/pages': r('../src/pages'),
          '@/widgets': r('../src/widgets'),
          '@/features': r('../src/features'),
          '@/entities': r('../src/entities'),
          '@/shared': r('../src/shared'),
        },
      },
    });
  },
};

export default config;
