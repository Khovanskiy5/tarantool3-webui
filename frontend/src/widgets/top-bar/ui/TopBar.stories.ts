/**
 * Stories for the application TopBar widget.
 *
 * TopBar shows the brand, the currently selected instance, and a
 * locale switcher. It takes no props — `useI18n` drives the title
 * and locale label, and the instance name will come from the
 * cluster entity store once Task 17 ships. Until then both states
 * (no instance vs. mocked instance via locale fallback) are
 * exercised through locale switching.
 */

import type { Meta, StoryObj } from '@storybook/vue3';
import { useI18n } from 'vue-i18n';
import { onMounted } from 'vue';

import { TopBar } from '@/widgets/top-bar';

type Story = StoryObj<typeof TopBar>;

const meta: Meta<typeof TopBar> = {
  title: 'Widgets/TopBar',
  component: TopBar,
  tags: ['autodocs'],
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component:
          'Top application bar with brand, current instance indicator '
          + 'and locale switcher. Renders identically against either '
          + 'locale; the instance label falls back to a "no instance" '
          + 'string until the cluster entity store lands.',
      },
    },
  },
};

export default meta;

// TopBar background is `--webui-bg-elevated`, which sits only a few
// brightness points above the page background `--webui-bg`. Without a
// visible "content area" below, the bar visually blends into the
// Storybook canvas and is easy to miss. The shell wrapper below adds
// a dashed border-top + a labelled placeholder so the bar's
// boundaries are obvious in both light and dark themes.
const makeStory = (locale: 'ru' | 'en'): Story => ({
  render: () => ({
    components: { TopBar },
    setup() {
      const i18n = useI18n();
      onMounted(() => {
        i18n.locale.value = locale;
      });
      return {};
    },
    template: `
      <div style="display: flex; flex-direction: column; min-height: 100vh; background: var(--webui-bg);">
        <TopBar />
        <main style="
          flex: 1;
          padding: 1.5rem;
          color: var(--webui-text-muted);
          border-top: 1px dashed var(--webui-border);
          font-family: var(--webui-font);
        ">
          (story content area — TopBar is the strip above)
        </main>
      </div>
    `,
  }),
});

export const Russian: Story = makeStory('ru');

export const English: Story = {
  ...makeStory('en'),
  parameters: {
    docs: {
      description: {
        story: 'Same component, English locale. Verifies that all i18n keys resolve in both locales.',
      },
    },
  },
};
