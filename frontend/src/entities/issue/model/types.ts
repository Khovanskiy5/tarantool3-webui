import type { IssueCardFieldsFragment } from '@/shared/api/generated';

export type Issue = IssueCardFieldsFragment;

export type IssueSeverity = Issue['severity'];
export type IssueCategory = Issue['category'];
export type IssueScope = Issue['scope'];
