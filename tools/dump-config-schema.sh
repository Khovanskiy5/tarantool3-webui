#!/bin/sh
#
# Pull the cluster-config JSON schema from a running Tarantool
# instance and write it to docker/configs/cluster.schema.json so the
# IDE can validate docker/configs/cluster.yaml against the same shape
# Tarantool's own config:apply() would.
#
# The schema is whatever `require('config'):jsonschema()` returns on
# the bound instance — that means it reflects the patched/extended
# tree this project ships (internal.config.extras unlocks
# config.etcd on CE etc.), not just the upstream definition.
#
# Why this lives outside the repo:
#   * regenerated per Tarantool version / per shim change
#   * pure local IDE convenience, not a runtime artefact
#   * ~500 KB JSON would noise up history if committed
#
# Prerequisites: `make dev` running. The script connects as
# `webui_peer` (the only user in dev with execute-on-universe).
set -eu

URI="${TARANTOOL_URI:-webui_peer:webui-peer-dev-password@localhost:3301}"
OUT="${OUT:-docker/configs/cluster.schema.json}"
INSTANCE="${INSTANCE:-webui-tt-1}"

# Drive the dump from inside the instance so the JSON does not have to
# pass through net.box's reply buffer (which truncates large blobs at
# ~512 KB by default).
tarantool -e "
local netbox = require('net.box')
local conn = netbox.connect('${URI}')
conn:wait_connected(5)
local size = conn:eval([=[
  local json = require('json')
  local fio = require('fio')
  local body = json.encode(require('config'):jsonschema())
  local f = fio.open('/tmp/cluster.schema.json',
                     {'O_WRONLY','O_CREAT','O_TRUNC'}, tonumber('644',8))
  f:write(body); f:close()
  return #body
]=])
io.stderr:write(string.format('schema: %d bytes written inside %s\n',
                              size, '${INSTANCE}'))
"

docker cp "${INSTANCE}:/tmp/cluster.schema.json" "${OUT}"
echo "wrote ${OUT} ($(wc -c < "${OUT}") bytes)"
