/**
 * Roundtrip tests for the binary helpers backing BinaryField.vue.
 *
 * Covers the cases where the naive `btoa(String.fromCharCode(...))`
 * approach falls apart: high-byte payloads, large buffers (chunked
 * path), and the operator-facing edge cases (whitespace inside
 * base64, plain-string fallback, strict UTF-8 rejection).
 */

import { describe, it, expect } from 'vitest';
import {
  base64ToBytes,
  bytesToBase64,
  envelopeOf,
  utf8DecodeStrict,
  utf8Encode,
} from './binary-helpers';

describe('bytesToBase64 / base64ToBytes', () => {
  it('roundtrips an ASCII payload', () => {
    const bytes = utf8Encode('hello world');
    const b64 = bytesToBase64(bytes);
    expect(b64).toBe('aGVsbG8gd29ybGQ=');
    expect(base64ToBytes(b64)).toEqual(bytes);
  });

  it('roundtrips a UTF-8 payload with multi-byte glyphs', () => {
    const bytes = utf8Encode('Привет, мир — 🚀');
    const back = base64ToBytes(bytesToBase64(bytes));
    expect(back).toEqual(bytes);
  });

  it('roundtrips arbitrary high bytes', () => {
    // High bytes break `btoa(String.fromCharCode(...))` if the
    // helper is not careful — every entry here is > 0x7f.
    const bytes = new Uint8Array([0x80, 0xff, 0xc3, 0xbf, 0x00, 0x01, 0x7f]);
    const back = base64ToBytes(bytesToBase64(bytes));
    expect(back).toEqual(bytes);
  });

  it('roundtrips a large buffer (chunked path)', () => {
    const bytes = new Uint8Array(70_000);
    for (let i = 0; i < bytes.length; i++) bytes[i] = i & 0xff;
    const back = base64ToBytes(bytesToBase64(bytes));
    expect(back.length).toBe(bytes.length);
    expect(back[0]).toBe(0x00);
    expect(back[256]).toBe(0x00);
    expect(back[69_999]).toBe(0x6f);
  });

  it('tolerates whitespace in pasted base64', () => {
    // Multi-line base64 copied from `openssl base64` etc.
    const bytes = utf8Encode('hello world');
    const split = 'aGVsbG8\n gd29ybGQ=';
    expect(base64ToBytes(split)).toEqual(bytes);
  });

  it('produces an empty result for the empty payload', () => {
    expect(bytesToBase64(new Uint8Array())).toBe('');
    expect(base64ToBytes('').length).toBe(0);
  });
});

describe('envelopeOf', () => {
  it('returns empty string for null / undefined', () => {
    expect(envelopeOf(null)).toBe('');
    expect(envelopeOf(undefined)).toBe('');
  });

  it('returns empty string for an empty envelope or empty plain string', () => {
    expect(envelopeOf({ _binary_base64: '' })).toBe('');
    expect(envelopeOf('')).toBe('');
  });

  it('passes through the canonical envelope', () => {
    expect(envelopeOf({ _binary_base64: 'aGVsbG8=' })).toBe('aGVsbG8=');
  });

  it('encodes a plain string as UTF-8 bytes', () => {
    // Mirrors how a legacy InputText feed re-enters BinaryField: the
    // operator typed ASCII into a string field, the parent passes
    // the plain string through. We treat it as UTF-8 bytes.
    expect(envelopeOf('hello')).toBe('aGVsbG8=');
  });
});

describe('utf8DecodeStrict', () => {
  it('decodes a valid UTF-8 payload', () => {
    expect(utf8DecodeStrict(utf8Encode('hi'))).toBe('hi');
    expect(utf8DecodeStrict(utf8Encode('🐱'))).toBe('🐱');
  });

  it('returns null on invalid UTF-8', () => {
    // 0xff alone is an invalid UTF-8 lead byte.
    expect(utf8DecodeStrict(new Uint8Array([0xff]))).toBeNull();
    // Truncated multi-byte sequence.
    expect(utf8DecodeStrict(new Uint8Array([0xe2, 0x82]))).toBeNull();
  });
});
