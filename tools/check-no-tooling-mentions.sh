#!/usr/bin/env bash
#
# Verify that the project tree is free of internal-tooling vocabulary.
#
# The rule (documented in CLAUDE.md / AGENTS.md) is that committed
# artefacts must read as if written by an ordinary engineering team —
# no references to the AI tooling used during development. This is
# enforced as a CI gate so a stray mention does not slip into a
# README, comment, or commit fragment.
#
# Allowlist:
#   * Local tooling state files: CLAUDE.md, AGENTS.md, .ai-factory/,
#     .claude/, .mcp.json, .ai-factory.json. These are in .gitignore
#     and never reach the wire.
#   * This script itself (the keywords are unavoidable here).
#
# Scope:
#   * Tracked files only (`git ls-files`). Untracked work-in-progress
#     and ignored tooling state are skipped.
#
# Exit code: 0 — clean. 1 — at least one violation.

set -euo pipefail

cd "$(dirname "$0")/.."

# Patterns to flag (Perl regex, case-insensitive). `\b` works under
# `git grep -P` (Perl), unlike `git grep -E` (POSIX ERE).
PATTERNS=(
  '\bclaude\b'
  '\bclaude code\b'
  '\bai[ _-]?factory\b'
  '\baif\b'
  '/aif-'
  '\banthropic\b'
  '\bmcp[ _-]?server\b'
  'co-authored-by:\s*claude'
)

# Files / dirs that are intentionally allowed to mention the tooling.
# Two categories:
#   1. Local tooling state — the artefacts themselves (gitignored,
#      defense in depth in case they ever get committed).
#   2. Build / ignore manifests — they MUST name the tooling paths to
#      exclude them from packaging or version control.
EXCLUDE_PATHSPECS=(
  ':!CLAUDE.md'
  ':!AGENTS.md'
  ':!.ai-factory'
  ':!.ai-factory/**'
  ':!.claude'
  ':!.claude/**'
  ':!.mcp.json'
  ':!.ai-factory.json'
  ':!.gitignore'
  ':!.dockerignore'
  ':!tools/check-no-tooling-mentions.sh'
)

violations=0

for pattern in "${PATTERNS[@]}"; do
  matches=$(git grep -nI -P -i "${pattern}" -- "${EXCLUDE_PATHSPECS[@]}" || true)
  if [[ -n "${matches}" ]]; then
    if (( violations == 0 )); then
      echo "FAIL: internal tooling mentions found in tracked files:"
      echo
    fi
    echo "Pattern: ${pattern}"
    while IFS= read -r line; do
      echo "  ${line}"
    done <<< "${matches}"
    echo
    violations=$((violations + 1))
  fi
done

if (( violations > 0 )); then
  echo "Found ${violations} pattern(s) with hits. See CLAUDE.md for the rule."
  echo "Allowed tooling-state paths are gitignored — if a real file should"
  echo "carry one of these words, narrow the regex above."
  exit 1
fi

echo "OK: no internal tooling mentions in tracked files."
