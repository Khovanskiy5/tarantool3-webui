/**
 * Shared binary helpers used by BinaryField.vue and its tests.
 *
 * `btoa` / `atob` are convenient but only handle binary strings —
 * they break on high-byte payloads. These helpers bridge `Uint8Array`
 * ↔ base64 (and ↔ UTF-8) without leaking that detail to callers.
 */

export function bytesToBase64(bytes: Uint8Array): string {
  // Chunk to avoid blowing the argument stack on large buffers.
  const CHUNK = 0x8000;
  let s = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    s += String.fromCharCode.apply(
      null,
      Array.from(bytes.subarray(i, i + CHUNK)),
    );
  }
  return btoa(s);
}

export function base64ToBytes(b64: string): Uint8Array {
  // Tolerate whitespace inside pasted base64. Strict mode would
  // surprise operators who copied a multi-line block.
  const cleaned = b64.replace(/\s+/g, '');
  const s = atob(cleaned);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function utf8Encode(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/**
 * Decode `bytes` as strict UTF-8 — returns null when the byte
 * sequence is not valid UTF-8. We want "no surrogate replacement"
 * semantics so the UI can disable the UTF-8 view honestly instead
 * of showing meaningless `�` characters.
 */
export function utf8DecodeStrict(bytes: Uint8Array): string | null {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/**
 * Read the wire shape that backs `BinaryField`'s v-model and return
 * the base64 representation. Accepts:
 *   * the canonical envelope `{ _binary_base64: string }`
 *   * a plain string (legacy / ASCII payload — treated as raw
 *     UTF-8 bytes)
 *   * `null` / `undefined`
 */
export interface BinaryEnvelope {
  _binary_base64: string;
}

export function envelopeOf(
  v: BinaryEnvelope | string | null | undefined,
): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') {
    return v === '' ? '' : bytesToBase64(utf8Encode(v));
  }
  return v._binary_base64 ?? '';
}
