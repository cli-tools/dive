#!/bin/bash
# Copyright (C) 2026 by Henrik Holst
# SPDX-License-Identifier: 0BSD
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

usage() {
    cat <<EOF
Usage: dive [options] [service] [-- command...]

A Docker Compose wrapper for interactive container development sessions.

Works with any compose file (compose.yaml, docker-compose.yml, etc.) or a
standalone Dockerfile. When no compose file is found, dive looks for a
Dockerfile and generates a minimal compose configuration automatically.

Options:
  -C PATH           Change to directory before doing anything
  -d, --detach      Start container in background without attaching
  -k, --keep-entrypoint  Keep original entrypoint (don't replace with sleep)
  -n, --no-build    Skip building the container
  -s, --shell PATH  Use specified shell (default: bash)
  -w, --working-dir PATH  Set working directory in container
  -h, --help        Show this help message

Configuration (x-dive extension in compose file):
  x-dive:
    service         Default service when multiple exist
    shell           Shell path or name (default: bash)
    init            Commands to run on container entry
    mounts          Host files/binaries to mount
    env             Environment variables
    target          Build target stage
    shm_size        Shared memory size (e.g. 2gb)
    command          Container command (implies keep_entrypoint)
    keep_entrypoint  Keep original entrypoint/command (default: false)
    working_dir     Working directory in container (e.g. /app)
    match_user      Run as host UID:GID inside container (default: true)
    network_mode    Network mode (e.g. host)
    ipc             IPC mode (e.g. host)

Project config (.dive.yaml in project directory):
  Same keys as above (without x-dive: wrapper). Overrides compose settings
  but is overridden by user config and CLI arguments.

Template variables (Go-like text/template syntax):
  {{.Service}}      Service name
  {{.Project}}      Compose project name
  {{.Shell}}        Selected shell

Templates are interpolated in env values, mount paths, and init commands.
Config is read from compose x-dive, then .dive.yaml, then user config, then CLI.
Later sources override earlier ones; mounts and env vars are merged.
EOF
    exit 0
}

USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/dive/config.yaml"
PROJECT_CONFIG=".dive.yaml"
CLEANUP_FILES=()

cleanup() {
    rm -f "${CLEANUP_FILES[@]}"
}
trap cleanup EXIT

# Interpolate template variables
interpolate() {
    local value="$1"
    value="${value//\{\{.Service\}\}/$SERVICE}"
    value="${value//\{\{.Project\}\}/$PROJECT}"
    value="${value//\{\{.Shell\}\}/$SHELL_NAME}"
    echo "$value"
}

# Safe variable expansion (no eval)
expand_vars() {
    local value="$1"
    # Expand $HOME and $XDG_* style variables safely
    while [[ "$value" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name}"
        value="${value/\$$var_name/$var_value}"
    done
    # Also handle ${VAR} syntax
    while [[ "$value" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name}"
        value="${value/\$\{$var_name\}/$var_value}"
    done
    echo "$value"
}

# Escape value for YAML double-quoted string
yaml_escape() {
    local value="$1"
    # Escape backslashes first, then double quotes
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    echo "$value"
}

# Process env vars from a yaml file into ENV_VARS associative array
process_env() {
    local file="$1"
    local base="$2"  # '["x-dive"]' for compose, '' for user config
    local keys k v prefix
    [[ -n "$base" ]] && prefix=".$base" || prefix=""
    keys=$(yq -r "${prefix}.env // {} | keys | .[]" "$file" 2>/dev/null) || return 0
    for k in $keys; do
        v=$(yq -r "${prefix}.env[\"$k\"]" "$file")
        v=$(interpolate "$v")
        ENV_VARS["$k"]="$v"
    done
}

# Process mounts from a yaml file into MOUNTS array
process_mounts() {
    local file="$1"
    local base="$2"  # '["x-dive"]' for compose, '' for user config
    local count prefix
    [[ -n "$base" ]] && prefix=".$base" || prefix=""
    count=$(yq "${prefix}.mounts | length // 0" "$file")

    for ((i = 0; i < count; i++)); do
        local entry entry_type
        entry=$(yq -r "${prefix}.mounts[$i]" "$file")
        entry_type=$(yq -r "${prefix}.mounts[$i] | type" "$file")

        if [[ "$entry_type" == "!!str" || "$entry_type" == "string" ]]; then
            # Interpolate template variables first
            entry=$(interpolate "$entry")

            if [[ "$entry" != *"/"* && "$entry" != *":"* ]]; then
                # Simple binary name
                local binary_path
                binary_path=$(type -p "$entry" 2>/dev/null || true)
                if [[ -n "$binary_path" ]]; then
                    MOUNTS+=("$binary_path:/usr/local/bin/$entry:ro")
                fi
            elif [[ "$entry" == *":"* ]]; then
                # Path string source:target[:mode]
                local source target mode
                source=$(echo "$entry" | cut -d: -f1)
                target=$(echo "$entry" | cut -d: -f2)
                mode=$(echo "$entry" | cut -d: -f3)
                source=$(expand_vars "$source")
                [[ -z "$mode" ]] && mode="ro"
                if [[ -e "$source" ]]; then
                    MOUNTS+=("$source:$target:$mode")
                fi
            fi
        elif [[ "$entry_type" == "!!map" || "$entry_type" == "object" ]]; then
            local binary source target mode
            binary=$(yq -r "${prefix}.mounts[$i].binary // \"\"" "$file")
            source=$(yq -r "${prefix}.mounts[$i].source // \"\"" "$file")
            target=$(yq -r "${prefix}.mounts[$i].target // \"\"" "$file")
            mode=$(yq -r "${prefix}.mounts[$i].mode // \"ro\"" "$file")

            # Interpolate template variables
            binary=$(interpolate "$binary")
            source=$(interpolate "$source")
            target=$(interpolate "$target")

            if [[ -n "$binary" ]]; then
                local binary_path
                binary_path=$(type -p "$binary" 2>/dev/null || true)
                if [[ -n "$binary_path" ]]; then
                    [[ -z "$target" ]] && target="/usr/local/bin/$binary"
                    MOUNTS+=("$binary_path:$target:$mode")
                fi
            elif [[ -n "$source" ]]; then
                source=$(expand_vars "$source")
                if [[ -e "$source" && -n "$target" ]]; then
                    MOUNTS+=("$source:$target:$mode")
                fi
            fi
        fi
    done
}

# Process compose service properties from a yaml file
process_service_props() {
    local file="$1"
    local base="$2"  # '["x-dive"]' for compose, '' for project/user config
    local prefix
    [[ -n "$base" ]] && prefix=".$base" || prefix=""
    for key in target shm_size working_dir network_mode ipc; do
        local val
        val=$(yq -r "${prefix}.${key} // \"\"" "$file" 2>/dev/null) || continue
        if [[ -n "$val" ]]; then
            val=$(expand_vars "$val")
            val=$(interpolate "$val")
            SERVICE_PROPS[$key]="$val"
        fi
    done
}

# Early scan for -C (must happen before compose file discovery)
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -C) cd "$2" || exit 1; shift 2 ;;
        -d|--detach) ARGS+=("$1"); shift ;;
        -k|--keep-entrypoint) ARGS+=("$1"); shift ;;
        --) ARGS+=("$@"); break ;;
        *)  ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

# Check dependencies
missing=()
type -p docker >/dev/null || missing+=(docker)
type -p yq >/dev/null || missing+=(yq)
docker compose version >/dev/null 2>&1 || missing+=("docker compose plugin")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Missing dependencies: ${missing[*]}" >&2
    exit 1
fi

# Get compose config once (handles any compose file name)
CONFIG_FILE="/tmp/dive-config-$$.yaml"
CLEANUP_FILES+=("$CONFIG_FILE")

# Read x-dive.profile directly from compose file before running config
# (needed because services with profiles are excluded from config output)
COMPOSE_FOUND=false
DIVE_PROFILE=""
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$f" ]]; then
        COMPOSE_FOUND=true
        DIVE_PROFILE=$(yq -r '.["x-dive"].profile // ""' "$f" 2>/dev/null) || true
        break
    fi
done
# Project config and user config can also set profile (higher priority)
if [[ -f "$PROJECT_CONFIG" ]]; then
    proj_profile=$(yq -r '.profile // ""' "$PROJECT_CONFIG" 2>/dev/null) || true
    [[ -n "$proj_profile" ]] && DIVE_PROFILE="$proj_profile"
fi
if [[ -f "$USER_CONFIG" ]]; then
    user_profile=$(yq -r '.profile // ""' "$USER_CONFIG" 2>/dev/null) || true
    [[ -n "$user_profile" ]] && DIVE_PROFILE="$user_profile"
fi
[[ -n "$DIVE_PROFILE" ]] && export COMPOSE_PROFILES="$DIVE_PROFILE"

if [[ "$COMPOSE_FOUND" == true ]] || docker compose config > "$CONFIG_FILE" 2>/dev/null; then
    # Compose file found (locally or via COMPOSE_FILE env var)
    if [[ "$COMPOSE_FOUND" == true ]]; then
        docker compose config > "$CONFIG_FILE" 2>/dev/null || {
            echo "Error: Invalid compose configuration" >&2
            exit 1
        }
    fi
elif [[ -f Dockerfile ]]; then
    # Fallback: generate a minimal compose file from Dockerfile
    GENERATED_COMPOSE="/tmp/dive-compose-$$.yaml"
    CLEANUP_FILES+=("$GENERATED_COMPOSE")
    cat > "$GENERATED_COMPOSE" << EOF
name: "$(basename "$PWD")"
services:
  app:
    build:
      context: "$PWD"
      dockerfile: Dockerfile
EOF
    docker compose -f "$GENERATED_COMPOSE" config > "$CONFIG_FILE" 2>/dev/null || {
        echo "Error: Failed to process generated compose file from Dockerfile" >&2
        exit 1
    }
else
    echo "Error: No compose file or Dockerfile found" >&2
    exit 1
fi

# Parse CLI arguments (highest priority)
CLI_NO_BUILD=false
CLI_DETACH=false
CLI_KEEP_ENTRYPOINT=false
CLI_SERVICE=""
CLI_SHELL=""
CLI_WORKING_DIR=""
CMD=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--detach) CLI_DETACH=true; shift ;;
        -k|--keep-entrypoint) CLI_KEEP_ENTRYPOINT=true; shift ;;
        -n|--no-build) CLI_NO_BUILD=true; shift ;;
        -s|--shell) CLI_SHELL="$2"; shift 2 ;;
        -w|--working-dir) CLI_WORKING_DIR="$2"; shift 2 ;;
        --) shift; CMD=("$@"); break ;;
        *) CLI_SERVICE="$1"; shift ;;
    esac
done

# Layer 1: Read from compose file (lowest priority)
SERVICE=$(yq -r '.["x-dive"].service // ""' "$CONFIG_FILE")
SHELL_NAME=$(yq -r '.["x-dive"].shell // "bash"' "$CONFIG_FILE")
INIT_CMD=$(yq -r '.["x-dive"].init // ""' "$CONFIG_FILE")
KEEP_ENTRYPOINT=$(yq -r '.["x-dive"].keep_entrypoint // "false"' "$CONFIG_FILE")
MATCH_USER=$(yq -r '.["x-dive"].match_user // "true"' "$CONFIG_FILE")
DIVE_COMMAND=$(yq -r '.["x-dive"].command // ""' "$CONFIG_FILE")
PROJECT=$(yq -r '.name // ""' "$CONFIG_FILE")
[[ -z "$PROJECT" ]] && PROJECT=$(basename "$PWD")

# Layer 2: Override with project config if exists
if [[ -f "$PROJECT_CONFIG" ]]; then
    proj_service=$(yq -r '.service // ""' "$PROJECT_CONFIG")
    proj_shell=$(yq -r '.shell // ""' "$PROJECT_CONFIG")
    proj_init=$(yq -r '.init // ""' "$PROJECT_CONFIG")
    proj_keep_ep=$(yq -r '.keep_entrypoint // ""' "$PROJECT_CONFIG")
    proj_match_user=$(yq -r '.match_user // ""' "$PROJECT_CONFIG")
    proj_command=$(yq -r '.command // ""' "$PROJECT_CONFIG")
    [[ -n "$proj_service" ]] && SERVICE="$proj_service"
    [[ -n "$proj_shell" ]] && SHELL_NAME="$proj_shell"
    [[ -n "$proj_init" ]] && INIT_CMD="$proj_init"
    [[ -n "$proj_keep_ep" ]] && KEEP_ENTRYPOINT="$proj_keep_ep"
    [[ -n "$proj_match_user" ]] && MATCH_USER="$proj_match_user"
    [[ -n "$proj_command" ]] && DIVE_COMMAND="$proj_command"
fi

# Layer 3: Override with user config if exists (uses short keys)
if [[ -f "$USER_CONFIG" ]]; then
    user_service=$(yq -r '.service // ""' "$USER_CONFIG")
    user_shell=$(yq -r '.shell // ""' "$USER_CONFIG")
    user_init=$(yq -r '.init // ""' "$USER_CONFIG")
    user_keep_ep=$(yq -r '.keep_entrypoint // ""' "$USER_CONFIG")
    user_match_user=$(yq -r '.match_user // ""' "$USER_CONFIG")
    user_command=$(yq -r '.command // ""' "$USER_CONFIG")
    [[ -n "$user_service" ]] && SERVICE="$user_service"
    [[ -n "$user_shell" ]] && SHELL_NAME="$user_shell"
    [[ -n "$user_init" ]] && INIT_CMD="$user_init"
    [[ -n "$user_keep_ep" ]] && KEEP_ENTRYPOINT="$user_keep_ep"
    [[ -n "$user_match_user" ]] && MATCH_USER="$user_match_user"
    [[ -n "$user_command" ]] && DIVE_COMMAND="$user_command"
fi

# Layer 4: Override with CLI arguments (highest priority)
[[ -n "$CLI_SERVICE" ]] && SERVICE="$CLI_SERVICE"
[[ -n "$CLI_SHELL" ]] && SHELL_NAME="$CLI_SHELL"
[[ "$CLI_KEEP_ENTRYPOINT" == true ]] && KEEP_ENTRYPOINT="true"
[[ -n "$DIVE_COMMAND" ]] && KEEP_ENTRYPOINT="true"
NO_BUILD="$CLI_NO_BUILD"

# Get available services
mapfile -t SERVICES < <(yq -r '.services | keys | .[]' "$CONFIG_FILE")

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    echo "Error: No services found in docker compose" >&2
    exit 1
fi

# Auto-detect service if not specified
if [[ -z "$SERVICE" ]]; then
    if [[ ${#SERVICES[@]} -eq 1 ]]; then
        SERVICE="${SERVICES[0]}"
    else
        echo "Error: Multiple services found. Specify one with x-dive.service or CLI:" >&2
        printf '  %s\n' "${SERVICES[@]}" >&2
        exit 1
    fi
fi

# Validate service exists
service_valid=false
for s in "${SERVICES[@]}"; do
    [[ "$s" == "$SERVICE" ]] && service_valid=true && break
done
if [[ "$service_valid" != true ]]; then
    echo "Error: Service '$SERVICE' not found. Available services:" >&2
    printf '  %s\n' "${SERVICES[@]}" >&2
    exit 1
fi

# Interpolate init command
[[ -n "$INIT_CMD" ]] && INIT_CMD=$(interpolate "$INIT_CMD")

# Process mounts (merged from compose + user config)
OVERRIDE_FILE="/tmp/dive-override-$$.yaml"
MOUNTS=()
process_mounts "$CONFIG_FILE" '["x-dive"]'
[[ -f "$PROJECT_CONFIG" ]] && process_mounts "$PROJECT_CONFIG" ""
[[ -f "$USER_CONFIG" ]] && process_mounts "$USER_CONFIG" ""

# Process env vars (merged from compose + project config + user config)
declare -A ENV_VARS
process_env "$CONFIG_FILE" '["x-dive"]'
[[ -f "$PROJECT_CONFIG" ]] && process_env "$PROJECT_CONFIG" ""
[[ -f "$USER_CONFIG" ]] && process_env "$USER_CONFIG" ""

# Process compose service properties (merged from all layers)
declare -A SERVICE_PROPS
process_service_props "$CONFIG_FILE" '["x-dive"]'
[[ -f "$PROJECT_CONFIG" ]] && process_service_props "$PROJECT_CONFIG" ""
[[ -f "$USER_CONFIG" ]] && process_service_props "$USER_CONFIG" ""
# Layer 4: CLI override for service props
[[ -n "$CLI_WORKING_DIR" ]] && SERVICE_PROPS[working_dir]="$CLI_WORKING_DIR"

# Build override file: neutralize entrypoint + add environment/volumes
CLEANUP_FILES+=("$OVERRIDE_FILE")
cat > "$OVERRIDE_FILE" << EOF
services:
  $SERVICE:
EOF
if [[ "$MATCH_USER" == "true" ]]; then
    echo "    user: \"$(id -u):$(id -g)\"" >> "$OVERRIDE_FILE"
fi
if [[ "$KEEP_ENTRYPOINT" != "true" ]]; then
    cat >> "$OVERRIDE_FILE" << EOF
    entrypoint: ["sleep", "infinity"]
    command: []
EOF
elif [[ -n "$DIVE_COMMAND" ]]; then
    echo "    command: $DIVE_COMMAND" >> "$OVERRIDE_FILE"
fi
if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    echo "    environment:" >> "$OVERRIDE_FILE"
    for key in "${!ENV_VARS[@]}"; do
        escaped=$(yaml_escape "${ENV_VARS[$key]}")
        echo "      $key: \"$escaped\"" >> "$OVERRIDE_FILE"
    done
fi
if [[ ${#MOUNTS[@]} -gt 0 ]]; then
    echo "    volumes:" >> "$OVERRIDE_FILE"
    for MOUNT in "${MOUNTS[@]}"; do
        echo "      - $MOUNT" >> "$OVERRIDE_FILE"
    done
fi
# Inject compose service properties
for key in shm_size working_dir network_mode ipc; do
    if [[ -n "${SERVICE_PROPS[$key]+x}" ]]; then
        escaped=$(yaml_escape "${SERVICE_PROPS[$key]}")
        echo "    $key: \"$escaped\"" >> "$OVERRIDE_FILE"
    fi
done
# network_mode and networks are mutually exclusive in compose
if [[ -n "${SERVICE_PROPS[network_mode]+x}" ]]; then
    echo "    networks: !reset []" >> "$OVERRIDE_FILE"
fi
if [[ -n "${SERVICE_PROPS[target]+x}" ]]; then
    escaped=$(yaml_escape "${SERVICE_PROPS[target]}")
    echo "    build:" >> "$OVERRIDE_FILE"
    echo "      target: \"$escaped\"" >> "$OVERRIDE_FILE"
fi
COMPOSE_CMD="docker compose -p $PROJECT -f $CONFIG_FILE -f $OVERRIDE_FILE"

if [[ "$NO_BUILD" == false ]]; then
    echo "Building $SERVICE... (skip with -n)" >&2
    if ! build_err=$($COMPOSE_CMD build -q "$SERVICE" 2>&1); then
        echo "Error: Failed to build service '$SERVICE'" >&2
        [[ -n "$build_err" ]] && echo "$build_err" >&2
        exit 1
    fi
fi

if ! up_err=$($COMPOSE_CMD up -d --quiet-pull "$SERVICE" 2>&1); then
    echo "Error: Failed to start service '$SERVICE'" >&2
    [[ -n "$up_err" ]] && echo "$up_err" >&2
    exit 1
fi

[[ "$CLI_DETACH" == true ]] && exit 0

EXEC_WORKDIR=()
if [[ -n "${SERVICE_PROPS[working_dir]+x}" ]]; then
    EXEC_WORKDIR=(-w "${SERVICE_PROPS[working_dir]}")
fi

# Command execution mode
if [[ ${#CMD[@]} -gt 0 ]]; then
    if [[ -n "$INIT_CMD" ]]; then
        $COMPOSE_CMD exec -it "${EXEC_WORKDIR[@]}" "$SERVICE" bash -c "set +eu; $INIT_CMD; ${CMD[*]}"
    else
        $COMPOSE_CMD exec -it "${EXEC_WORKDIR[@]}" "$SERVICE" "${CMD[@]}"
    fi
    exit $?
fi

# Interactive shell mode: init in bash, then exec into requested shell
if [[ -n "$INIT_CMD" ]]; then
    $COMPOSE_CMD exec -it "${EXEC_WORKDIR[@]}" "$SERVICE" bash -c "set +eu; $INIT_CMD; exec $SHELL_NAME"
else
    $COMPOSE_CMD exec -it "${EXEC_WORKDIR[@]}" "$SERVICE" "$SHELL_NAME"
fi
