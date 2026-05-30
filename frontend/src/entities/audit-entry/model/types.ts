export interface AuditEntry {
  id: number;
  ts: number;
  user: string | null;
  action: string;
  scope: string | null;
  request_id: string | null;
  payload: string | null;
}

export interface AuditPage {
  entries: AuditEntry[];
  next_cursor: number | null;
  has_more: boolean;
}

export interface AuditFilter {
  user?: string;
  action?: string;
  scope?: string;
  from_ts?: number;
  to_ts?: number;
}
