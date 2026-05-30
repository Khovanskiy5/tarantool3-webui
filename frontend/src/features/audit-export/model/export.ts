import { getClient } from '@/shared/api/graphql';
import type { AuditFilter } from '@/entities/audit-entry';

const EXPORT_MUTATION = /* GraphQL */ `
  mutation ExportAudit($filter: AuditFilter) {
    exportAudit(filter: $filter) {
      format
      body
      record_count
    }
  }
`;

export interface ExportResult {
  format: string;
  body: string;
  record_count: number;
}

export const exportAudit = async (filter: AuditFilter = {}): Promise<ExportResult | null> => {
  const client = getClient();
  const res = await client
    .mutation<{ exportAudit: ExportResult }>(EXPORT_MUTATION, { filter })
    .toPromise();
  if (res.error || res.data == null) return null;
  return res.data.exportAudit;
};

export const downloadExportedAudit = async (filter: AuditFilter = {}): Promise<void> => {
  const result = await exportAudit(filter);
  if (result == null) return;
  const blob = new Blob([result.body], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `audit-${Date.now()}.json`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
};
