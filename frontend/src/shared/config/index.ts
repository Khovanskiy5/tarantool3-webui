/**
 * Build-time configuration exposed to the frontend.
 *
 * Anything that may vary between environments (API base URL, feature
 * flags) is read from Vite env vars prefixed with VITE_ and surfaced
 * here as typed constants. Runtime config (cluster settings) comes from
 * GraphQL / REST and lives in the appropriate entity stores.
 */

export const APP_VERSION = (import.meta.env.VITE_APP_VERSION as string | undefined) ?? '0.1.0';
export const APP_BASE_URL = (import.meta.env.VITE_APP_BASE_URL as string | undefined) ?? '/';
export const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL as string | undefined) ?? '';
export const WS_PATH = '/ws';
export const GRAPHQL_PATH = '/admin/api';

export const IS_DEV = import.meta.env.DEV;
