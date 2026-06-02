/**
 * Small formatting helpers shared across widgets that have to render
 * numeric stats without dragging in a heavyweight i18n library.
 *
 * `formatBytes` mirrors what `@tarantool.io/ui-kit` ships in Cartridge:
 * always divide down to KiB first, then keep stepping up while the
 * value crosses 1024. The clamp at 0.1 prevents "0.0 KiB" labels that
 * read as missing data — for the storage stats we render this powers
 * the tooltip on the cluster page, so callers can rely on the result
 * never being shorter than a few characters.
 */

const BYTE_UNITS = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'] as const;

export function formatBytes(size: number | null | undefined): string {
  if (size == null || !Number.isFinite(size)) return '—';
  let bytes = size;
  let i = -1;
  do {
    bytes = bytes / 1024;
    i += 1;
  } while (bytes > 1024 && i < BYTE_UNITS.length - 1);
  return `${Math.max(bytes, 0.1).toFixed(1)} ${BYTE_UNITS[i]}`;
}

/**
 * Format a small integer with the user's locale thousand separators.
 * `Intl.NumberFormat` uses the active document locale; we accept an
 * explicit override so deterministic tests stay reproducible.
 */
export function formatInteger(value: number | null | undefined, locale?: string): string {
  if (value == null || !Number.isFinite(value)) return '—';
  return new Intl.NumberFormat(locale).format(Math.trunc(value));
}
