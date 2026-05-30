/**
 * Storybook 8 manager UI customization.
 *
 * Sets the sidebar branding so the Storybook chrome reads as the
 * project's component library rather than the generic Storybook
 * defaults. Everything else (toolbar, addon panel) stays default.
 */

import { addons } from '@storybook/manager-api';
import { create } from '@storybook/theming';

addons.setConfig({
  theme: create({
    base: 'dark',
    brandTitle: 'Tarantool WebUI · Components',
    brandUrl: '/',
    colorPrimary: '#4ea8de',
    colorSecondary: '#4ea8de',
    appBg: '#0e1117',
    appContentBg: '#0e1117',
    appBorderColor: '#30363d',
    textColor: '#e6e6e6',
    barTextColor: '#8b949e',
    barSelectedColor: '#4ea8de',
    barBg: '#161b22',
  }),
});
