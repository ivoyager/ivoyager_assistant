#!/usr/bin/env bash
# assistant_client.sh - Send JSON-RPC commands to the I, Voyager AssistantServer
#
# Usage:
#   ./assistant_client.sh <method> [params_json]
#
# Examples:
#   ./assistant_client.sh get_state
#   ./assistant_client.sh list_bodies '{"filter":"planets"}'
#   ./assistant_client.sh select_body '{"name":"PLANET_MARS"}'
#   ./assistant_client.sh set_speed '{"index":3}'
#   ./assistant_client.sh set_pause '{"paused":true}'
#   ./assistant_client.sh quit '{"force":true}'
#
# Environment variables:
#   ASSISTANT_HOST  - default: 127.0.0.1
#   ASSISTANT_PORT  - default: 29071

set -euo pipefail

HOST="${ASSISTANT_HOST:-127.0.0.1}"
PORT="${ASSISTANT_PORT:-29071}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <method> [params_json]" >&2
    echo "  e.g. $0 get_state" >&2
    echo "  e.g. $0 select_body '{\"name\":\"PLANET_MARS\"}'" >&2
    exit 1
fi

METHOD="$1"
DEFAULT_PARAMS='{}'
PARAMS="${2:-$DEFAULT_PARAMS}"

# Build JSON request
REQUEST="{\"id\":1,\"method\":\"${METHOD}\",\"params\":${PARAMS}}"

# Send via bash /dev/tcp (works in bash on Windows/Git Bash, Linux, macOS)
exec 3<>/dev/tcp/"$HOST"/"$PORT"
echo "$REQUEST" >&3

# Read response (single line)
read -r -t 5 RESPONSE <&3 || true
exec 3<&-

if [ -z "${RESPONSE:-}" ]; then
    echo "Error: no response from $HOST:$PORT (is the application running?)" >&2
    exit 1
fi

echo "$RESPONSE"
