#!/usr/bin/env bash
#
# Refresh GraphQL SDL and TypeScript types.
#
# Two-stage:
#   1. tarantool tools/dump-schema.lua → frontend/src/shared/api/schema.graphql
#   2. bunx graphql-codegen --config frontend/codegen.yml → frontend/src/shared/api/generated.ts
#
# The script intentionally does not start the backend — `dump-schema.lua`
# loads the schema module directly. CI runs this from the repo root
# without any docker-compose dependency.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
SDL_PATH="${REPO_ROOT}/frontend/src/shared/api/schema.graphql"

echo "gen-types: dumping SDL to ${SDL_PATH#"${REPO_ROOT}"/} …"
mkdir -p "$(dirname "$SDL_PATH")"
tarantool tools/dump-schema.lua "$SDL_PATH"

echo "gen-types: running graphql-codegen via bun …"
cd "${REPO_ROOT}/frontend"
bunx graphql-codegen --config codegen.yml

echo "gen-types: done."
