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
  /** Prefix match on the action string, e.g. `cluster.` covers every Phase 5 operator mutation. */
  action_prefix?: string;
  scope?: string;
  from_ts?: number;
  to_ts?: number;
}
