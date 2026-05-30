/**
 * Stories for the primary navigation Sidebar widget.
 *
 * Sidebar takes no props — its appearance depends on the active
 * route (rendered by `useRoute`) and on the i18n locale. The
 * preview decorators in `.storybook/preview.ts` already inject
 * an in-memory router, so each story below just sets the
 * `initialRoute` parameter to control which item highlights.
 */

import type { Meta, StoryObj } from '@storybook/vue3';
import { useRouter } from 'vue-router';
import { onMounted } from 'vue';

import { Sidebar } from '@/widgets/sidebar';

type Story = StoryObj<typeof Sidebar>;

const meta: Meta<typeof Sidebar> = {
  title: 'Widgets/Sidebar',
  component: Sidebar,
  tags: ['autodocs'],
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component:
          'Primary navigation rail. One entry per top-level admin area. '
          + 'The active item is derived from the current route segment '
          + 'so the highlight survives in-app navigation without prop drilling.',
      },
    },
  },
};

export default meta;

// Helper component that swaps the router to a chosen route before
// rendering Sidebar. Each story can then ask for a specific active
// segment without duplicating router wiring. The placeholder main
// area to the right makes the rail's boundary obvious — without it
// Sidebar appears to "leak" into the Storybook canvas because the
// surrounding background is the same dark colour.
const makeStory = (initialRoute: string): Story => ({
  render: () => ({
    components: { Sidebar },
    setup() {
      const router = useRouter();
      onMounted(() => {
        void router.push(initialRoute);
      });
      return {};
    },
    template: `
      <div style="display: flex; min-height: 100vh; background: var(--webui-bg);">
        <Sidebar />
        <main style="
          flex: 1;
          padding: 1.5rem;
          color: var(--webui-text-muted);
          border-left: 1px dashed var(--webui-border);
          font-family: var(--webui-font);
        ">
          (story content area — Sidebar is the rail on the left)
        </main>
      </div>
    `,
  }),
});

export const Default: Story = makeStory('/cluster');

export const IssuesActive: Story = {
  ...makeStory('/issues'),
  parameters: {
    docs: {
      description: {
        story: 'The Issues entry is highlighted when the route segment matches `/issues`.',
      },
    },
  },
};

export const ConfigEditorActive: Story = makeStory('/config-editor');
export const FailoverActive: Story = makeStory('/failover');
export const ConsoleActive: Story = makeStory('/console');
