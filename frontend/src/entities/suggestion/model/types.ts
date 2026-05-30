import type {
  ForceApplyFieldsFragment,
  RestartReplicationFieldsFragment,
  SuggestionsOverviewQuery,
} from '@/shared/api/generated';

export type ForceApplySuggestion = ForceApplyFieldsFragment;
export type RestartReplicationSuggestion = RestartReplicationFieldsFragment;

export type SuggestionsOverview = NonNullable<SuggestionsOverviewQuery['suggestions']>;
