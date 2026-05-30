#!/usr/bin/env bash
#
# Entrypoint for the webui-instance image.
#
# Resolves the instance name and config path from environment variables,
# prints a structured banner of the resolved configuration, then execs
# `tarantool` so the instance receives SIGTERM directly (no shell-level
# signal forwarding required).
#
# Both `INSTANCE_NAME` and `TT_INSTANCE_NAME` are accepted: the former
# is the human-friendly name we use in docker-compose env blocks, the
# latter is the official Tarantool env. Same for CONFIG / TT_CONFIG.
#
# Exit codes:
#   64  — missing INSTANCE_NAME
#   65  — config file not found
#   66  — config file unreadable
#   anything else — propagated from tarantool itself

set -euo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-${TT_INSTANCE_NAME:-}}"
CONFIG_PATH="${TT_CONFIG:-/opt/webui/etc/instance.yaml}"
WEBUI_PORT="${WEBUI_PORT:-8081}"
WEBUI_LOG_LEVEL="${WEBUI_LOG_LEVEL:-info}"
TT_WORK_DIR="${TT_WORK_DIR:-/opt/webui/var/lib}"

# Sanity print. Goes to stdout so docker logs / compose logs / k8s logs
# all show the resolved configuration on instance start. No secrets here.
banner() {
    printf '[entrypoint] starting webui-instance\n'
    printf '[entrypoint]   instance        = %s\n' "${INSTANCE_NAME:-<unset>}"
    printf '[entrypoint]   config          = %s\n' "${CONFIG_PATH}"
    printf '[entrypoint]   work-dir        = %s\n' "${TT_WORK_DIR}"
    printf '[entrypoint]   webui-port      = %s\n' "${WEBUI_PORT}"
    printf '[entrypoint]   log-level       = %s\n' "${WEBUI_LOG_LEVEL}"
    printf '[entrypoint]   tarantool       = %s\n' "$(tarantool --version 2>/dev/null | head -1 || echo unknown)"
    printf '[entrypoint]   uid:gid         = %s:%s\n' "$(id -u)" "$(id -g)"
}

banner

if [[ -z "${INSTANCE_NAME}" ]]; then
    printf '[entrypoint] ERROR: INSTANCE_NAME (or TT_INSTANCE_NAME) is required\n' >&2
    exit 64
fi

if [[ ! -e "${CONFIG_PATH}" ]]; then
    printf '[entrypoint] ERROR: config file not found: %s\n' "${CONFIG_PATH}" >&2
    printf '[entrypoint]        mount your cluster config to that path, or set TT_CONFIG.\n' >&2
    exit 65
fi
if [[ ! -r "${CONFIG_PATH}" ]]; then
    printf '[entrypoint] ERROR: config file not readable: %s\n' "${CONFIG_PATH}" >&2
    exit 66
fi

# Ensure work-dir exists and is writable by the current process. The
# image already creates /opt/webui/var/lib, but a bind-mount may shadow
# it with an empty volume.
mkdir -p "${TT_WORK_DIR}"

# Export normalised env so the role and tarantool itself see consistent
# values regardless of whether the caller used the WEBUI_* or TT_*
# spelling.
export TT_CONFIG="${CONFIG_PATH}"
export TT_INSTANCE_NAME="${INSTANCE_NAME}"
export TT_WORK_DIR
export WEBUI_LOG_LEVEL
export WEBUI_PORT

cd "${TT_WORK_DIR}"

# exec → pid 1 stays tarantool, signals flow directly.
exec tarantool --name "${INSTANCE_NAME}" --config "${CONFIG_PATH}"
