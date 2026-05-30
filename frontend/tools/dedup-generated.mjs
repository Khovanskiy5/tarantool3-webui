#!/usr/bin/env node
/**
 * Post-codegen dedup for src/shared/api/generated.ts.
 *
 * graphql-codegen emits a few enum types twice when an operation
 * uses them as `$variable` kinds (IssueSeverity / IssueScope /
 * IssueCategory). None of the official knobs (onlyOperationTypes,
 * preResolveTypes, inlineFragmentTypes) suppress the duplicate.
 *
 * The script keeps the first declaration of each enum-shaped
 * `export type` block and drops every later occurrence with the
 * same name. The regex is pinned to the exact codegen output
 * shape (single-line JSDoc + `| 'CONST'` chain ending with `;`)
 * so it can never gobble up unrelated object-type declarations
 * (Server, Replicaset, ServerPage) between two copies.
 */
import { readFileSync, writeFileSync } from 'node:fs';

const target = new URL('../src/shared/api/generated.ts', import.meta.url);
const src = readFileSync(target, 'utf8');

// Matches:
//   /** Optional one-line JSDoc */
//   export type Name =
//     | 'CONST_A'
//     | 'CONST_B'
//     | 'CONST_C';
const enumRe = /(?:\/\*\* [^\n]*\*\/\n)?export type ([A-Za-z0-9_]+) =\n(?:  \| '[A-Z_]+'\n)+\s*\| '[A-Z_]+';\n/g;

const firstSeen = new Set();
const out = src.replace(enumRe, (match, name) => {
  if (firstSeen.has(name)) return '';
  firstSeen.add(name);
  return match;
});

writeFileSync(target, out);
