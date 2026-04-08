#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# GitNexus Gateway - Container Entrypoint
# ==============================================================================

readonly DEFAULT_PUID=1000
readonly DEFAULT_PGID=1000
readonly DEFAULT_PORT=8010
readonly DEFAULT_INTERNAL_PORT=38011
readonly DEFAULT_PROTOCOL="SHTTP"
readonly DEFAULT_DATA_DIR="/data"
readonly SAFE_API_KEY_REGEX='^[[:graph:]]+$'
readonly MIN_API_KEY_LEN=5
readonly MAX_API_KEY_LEN=256

readonly HAPROXY_SERVER_NAME="gitnexus"
readonly HAPROXY_TEMPLATE="/etc/haproxy/haproxy.cfg.template"
readonly HAPROXY_CONFIG="/tmp/haproxy.cfg"
readonly REGISTRY_DIR="/home/node/.gitnexus"

readonly STATE_DIR="/state"
readonly FIRST_RUN_FILE="${STATE_DIR}/first_run_complete"
readonly ANALYSIS_LOCK="${STATE_DIR}/.analyzing"
readonly CLEAN_DONE_FILE="${STATE_DIR}/.clean_done"
readonly CLEAN_ALL_DONE_FILE="${STATE_DIR}/.clean_all_done"
readonly ANALYZE_FORCE_DONE_FILE="${STATE_DIR}/.analyze_force_done"
readonly WIKI_FORCE_DONE_FILE="${STATE_DIR}/.wiki_force_done"

# ==============================================================================
# Utility functions
# ==============================================================================

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ==============================================================================
# Validation functions
# ==============================================================================

validate_port() {
    local name="$1"
    local value="$2"
    local fallback="$3"

    if ! is_positive_int "$value" || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "Invalid ${name}='${value}', using default ${fallback}" >&2
        printf '%s' "$fallback"
        return
    fi
    printf '%s' "$value"
}

validate_api_key() {
    API_KEY="${API_KEY:-}"
    API_KEY="$(trim "$API_KEY")"

    if [[ -z "$API_KEY" ]]; then
        export API_KEY=""
        return
    fi

    local api_key_len="${#API_KEY}"
    if (( api_key_len < MIN_API_KEY_LEN || api_key_len > MAX_API_KEY_LEN )); then
        echo "Invalid API_KEY length (${api_key_len}). Expected ${MIN_API_KEY_LEN}-${MAX_API_KEY_LEN} characters." >&2
        exit 1
    fi

    if [[ ! "$API_KEY" =~ $SAFE_API_KEY_REGEX ]]; then
        echo "Invalid API_KEY format. Refusing to start with malformed API key (whitespace/control chars are not allowed)." >&2
        exit 1
    fi

    export API_KEY
}

validate_cors() {
    ALLOW_ALL_CORS=false
    HAPROXY_CORS_ENABLED=false
    HAPROXY_CORS_ORIGINS=()

    if [[ -z "${CORS:-}" ]]; then
        return
    fi

    HAPROXY_CORS_ENABLED=true
    IFS=',' read -ra CORS_VALUES <<< "$CORS"
    local cors_value
    for cors_value in "${CORS_VALUES[@]}"; do
        cors_value="$(trim "$cors_value")"
        [[ -z "$cors_value" ]] && continue

        if [[ "$cors_value" =~ ^(all|\*)$ ]]; then
            ALLOW_ALL_CORS=true
            HAPROXY_CORS_ORIGINS=("*")
            break
        elif [[ "$cors_value" =~ ^https?:// ]]; then
            HAPROXY_CORS_ORIGINS+=("$cors_value")
        elif [[ "$cors_value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?$ ]]; then
            HAPROXY_CORS_ORIGINS+=("http://$cors_value" "https://$cors_value")
        elif [[ "$cors_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            HAPROXY_CORS_ORIGINS+=("http://$cors_value" "https://$cors_value")
        else
            echo "Warning: Invalid CORS pattern '$cors_value' - skipping"
        fi
    done
}

# ==============================================================================
# First run: PUID/PGID handling
# ==============================================================================

handle_first_run() {
    local uid_gid_changed=0

    if [[ -z "${PUID:-}" && -z "${PGID:-}" ]]; then
        PUID="$DEFAULT_PUID"
        PGID="$DEFAULT_PGID"
    elif [[ -n "${PUID:-}" && -z "${PGID:-}" ]]; then
        is_positive_int "$PUID" || PUID="$DEFAULT_PUID"
        PGID="$PUID"
    elif [[ -z "${PUID:-}" && -n "${PGID:-}" ]]; then
        is_positive_int "$PGID" || PGID="$DEFAULT_PGID"
        PUID="$PGID"
    else
        is_positive_int "$PUID" || PUID="$DEFAULT_PUID"
        is_positive_int "$PGID" || PGID="$DEFAULT_PGID"
    fi

    if [ "$(id -u node)" -ne "$PUID" ]; then
        if usermod -o -u "$PUID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            PUID="$(id -u node)"
        fi
    fi

    if [ "$(id -g node)" -ne "$PGID" ]; then
        if groupmod -o -g "$PGID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            PGID="$(id -g node)"
        fi
    fi

    if [ "$uid_gid_changed" -eq 1 ]; then
        echo "Updated UID/GID to PUID=${PUID}, PGID=${PGID}"
    fi

    touch "$FIRST_RUN_FILE"
}

# ==============================================================================
# HAProxy configuration generation
# ==============================================================================

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s' "$value"
}

generate_haproxy_config() {
    if [[ ! -f "$HAPROXY_TEMPLATE" ]]; then
        echo "Error: HAProxy template missing at ${HAPROXY_TEMPLATE}" >&2
        exit 1
    fi

    # API Key check block
    local api_key_check
    if [[ -n "$API_KEY" ]]; then
        local escaped_key_sed
        escaped_key_sed="$(escape_sed_replacement "$API_KEY")"
        api_key_check="    # API Key authentication enabled (/healthz always excluded)
    acl auth_header_present var(txn.auth_header) -m found

    # Extract token: strip 'Bearer ' prefix (case-insensitive) into txn.api_token
    http-request set-var(txn.api_token) var(txn.auth_header),regsub(^[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+,)

    # Validate extracted token via exact string match
    acl auth_valid var(txn.api_token) -m str ${escaped_key_sed}

    # Deny requests without valid authentication (health checks always bypass auth)
    http-request deny deny_status 401 content-type \"application/json\" string '{\"error\":\"Unauthorized\",\"message\":\"Valid API key required\"}' if !is_health_check !auth_header_present
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Invalid API key\"}' if !is_health_check auth_header_present !auth_valid"
    else
        api_key_check="    # API Key authentication disabled - all requests allowed"
    fi

    # CORS check block
    local cors_check
    local cors_preflight_condition
    local cors_response_condition

    if [[ "$HAPROXY_CORS_ENABLED" == "true" ]]; then
        if [[ "$ALLOW_ALL_CORS" == "true" ]]; then
            cors_check="    # CORS enabled - allowing ALL origins"
            cors_preflight_condition="{ var(txn.origin) -m found }"
            cors_response_condition="{ var(txn.origin) -m found }"
        else
            cors_check="    # CORS enabled - allowing specific origins
    acl cors_origin_allowed var(txn.origin) -m str -i"

            local origin
            for origin in "${HAPROXY_CORS_ORIGINS[@]}"; do
                cors_check+=" ${origin}"
            done

            cors_check+="
    # Deny requests from non-allowed origins
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Origin not allowed\"}' if { var(txn.origin) -m found } !cors_origin_allowed"
            cors_preflight_condition="cors_origin_allowed"
            cors_response_condition="cors_origin_allowed"
        fi
    else
        cors_check="    # CORS disabled"
        cors_preflight_condition="{ always_false }"
        cors_response_condition="{ always_false }"
    fi

    # Generate config from template
    sed -e "s|__SERVER_PORT__|${PORT}|g" \
        -e "s|__INTERNAL_PORT__|${INTERNAL_PORT}|g" \
        -e "s|__SERVER_NAME__|${HAPROXY_SERVER_NAME}|g" \
        -e "s|__CORS_PREFLIGHT_CONDITION__|${cors_preflight_condition}|g" \
        -e "s|__CORS_RESPONSE_CONDITION__|${cors_response_condition}|g" \
        "$HAPROXY_TEMPLATE" > "${HAPROXY_CONFIG}.tmp"

    awk -v replacement="$api_key_check" -v replacement_cors="$cors_check" '
        /__API_KEY_CHECK__/ {
            print replacement
            next
        }
        /__CORS_CHECK__/ {
            print replacement_cors
            next
        }
        { print }
    ' "${HAPROXY_CONFIG}.tmp" > "$HAPROXY_CONFIG"

    rm -f "${HAPROXY_CONFIG}.tmp"

    haproxy -c -f "$HAPROXY_CONFIG" >/dev/null
}

# ==============================================================================
# Service management
# ==============================================================================

start_haproxy() {
    echo "Starting HAProxy on port ${PORT}"
    haproxy -db -f "$HAPROXY_CONFIG" &
    HAPROXY_PID=$!
}

register_repo_if_indexed() {
    local repo_dir="$1"
    local run_cmd=()

    if [[ ! -f "$repo_dir/.gitnexus/meta.json" ]]; then
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    echo "Registering indexed repository: ${repo_dir}"
    (cd "$repo_dir" && "${run_cmd[@]}" gitnexus index 2>&1) || \
        echo "Warning: gitnexus index failed for ${repo_dir}"
}

# ==============================================================================
# GitNexus operations
# ==============================================================================

run_gitnexus_clean() {
    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    if is_true "${CLEAN_ALL_FORCE:-false}"; then
        if [[ -f "$CLEAN_ALL_DONE_FILE" ]]; then
            echo "Clean --all --force already completed this container lifecycle, skipping"
            return
        fi
        echo "Running gitnexus clean --all --force..."
        if "${run_cmd[@]}" gitnexus clean --all --force; then
            touch "$CLEAN_ALL_DONE_FILE"
        else
            echo "Warning: gitnexus clean --all --force returned non-zero (will retry on next restart)"
        fi
        return
    fi

    if is_true "${CLEAN_ON_START:-false}"; then
        if [[ -f "$CLEAN_DONE_FILE" ]]; then
            echo "Clean already completed this container lifecycle, skipping"
            return
        fi
        echo "Running gitnexus clean..."
        if "${run_cmd[@]}" gitnexus clean; then
            touch "$CLEAN_DONE_FILE"
        else
            echo "Warning: gitnexus clean returned non-zero (will retry on next restart)"
        fi
    fi
}

run_gitnexus_analyze() {
    local data_dir="$1"

    if [[ ! -d "$data_dir" ]]; then
        echo "Warning: DATA_DIR='${data_dir}' does not exist. Skipping analysis."
        return
    fi

    local analyze_args=()

    if is_true "${ANALYZE_FORCE:-false}"; then
        if [[ -f "$ANALYZE_FORCE_DONE_FILE" ]]; then
            echo "Force analysis already completed this container lifecycle, skipping --force"
        else
            analyze_args+=("--force")
        fi
    fi

    is_true "${ANALYZE_SKILLS:-false}" && analyze_args+=("--skills")
    is_true "${ANALYZE_EMBEDDINGS:-false}" && analyze_args+=("--embeddings")
    is_true "${ANALYZE_SKIP_GIT:-false}" && analyze_args+=("--skip-git")
    is_true "${ANALYZE_VERBOSE:-false}" && analyze_args+=("--verbose")

    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    local found_repos=0
    for repo_dir in "$data_dir"/*/; do
        if [[ -d "$repo_dir" ]]; then
            found_repos=1
            echo "Analyzing repository: ${repo_dir}"
            (cd "$repo_dir" && "${run_cmd[@]}" gitnexus analyze "${analyze_args[@]}" 2>&1) || \
                echo "Warning: gitnexus analyze failed for ${repo_dir}"
            register_repo_if_indexed "$repo_dir"
        fi
    done

    if [[ "$found_repos" -eq 0 ]]; then
        echo "No subdirectories found in ${data_dir}. Analyzing root data directory..."
        (cd "$data_dir" && "${run_cmd[@]}" gitnexus analyze "${analyze_args[@]}" 2>&1) || \
            echo "Warning: gitnexus analyze failed for ${data_dir}"
        register_repo_if_indexed "$data_dir"
    fi

    if is_true "${ANALYZE_FORCE:-false}" && [[ ! -f "$ANALYZE_FORCE_DONE_FILE" ]]; then
        touch "$ANALYZE_FORCE_DONE_FILE"
    fi
}

run_gitnexus_wiki() {
    if ! is_true "${WIKI_ENABLED:-false}"; then
        return
    fi

    local data_dir="$1"
    local wiki_args=()

    [[ -n "${WIKI_MODEL:-}" ]] && wiki_args+=("--model" "$WIKI_MODEL")
    [[ -n "${WIKI_BASE_URL:-}" ]] && wiki_args+=("--base-url" "$WIKI_BASE_URL")

    if is_true "${WIKI_FORCE:-false}"; then
        if [[ -f "$WIKI_FORCE_DONE_FILE" ]]; then
            echo "Force wiki generation already completed this container lifecycle, skipping --force"
        else
            wiki_args+=("--force")
        fi
    fi

    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    for repo_dir in "$data_dir"/*/; do
        if [[ -d "$repo_dir" ]]; then
            echo "Generating wiki for: ${repo_dir}"
            (cd "$repo_dir" && "${run_cmd[@]}" gitnexus wiki "${wiki_args[@]}" 2>&1) || \
                echo "Warning: gitnexus wiki failed for ${repo_dir}"
        fi
    done

    if is_true "${WIKI_FORCE:-false}" && [[ ! -f "$WIKI_FORCE_DONE_FILE" ]]; then
        touch "$WIKI_FORCE_DONE_FILE"
    fi
}

start_mcp_server() {
    local CMD_ARGS

    case "${PROTOCOL^^}" in
        SHTTP|STREAMABLEHTTP|'')
            ;;
        *)
            echo "Warning: PROTOCOL='${PROTOCOL}' is not supported by the native GitNexus HTTP server; using StreamableHTTP via /api/mcp" >&2
            ;;
    esac

    CMD_ARGS=(gitnexus serve --host 0.0.0.0 --port "$INTERNAL_PORT")
    PROTOCOL_DISPLAY="HTTP + MCP-over-StreamableHTTP"

    echo "Launching GitNexus native HTTP server with shared multi-repo backend"

    if [ "$(id -u)" -eq 0 ]; then
        gosu node "${CMD_ARGS[@]}" &
    else
        "${CMD_ARGS[@]}" &
    fi

    MCP_PID=$!

    # Wait for MCP server to be ready
    local i=0
    until nc -z 127.0.0.1 "$INTERNAL_PORT" >/dev/null 2>&1; do
        if ! kill -0 "$MCP_PID" >/dev/null 2>&1; then
            echo "MCP server exited before becoming ready" >&2
            return 1
        fi
        i=$((i + 1))
        if [ "$i" -ge 30 ]; then
            echo "MCP server did not become ready on ${INTERNAL_PORT}" >&2
            return 1
        fi
        sleep 1
    done
}

# ==============================================================================
# Shutdown handler
# ==============================================================================

shutdown() {
    set +e
    if [[ -n "${HAPROXY_PID:-}" ]]; then
        kill "$HAPROXY_PID" 2>/dev/null || true
    fi
    if [[ -n "${MCP_PID:-}" ]]; then
        kill "$MCP_PID" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    # If arguments are passed, exec them directly (e.g., docker run ... bash)
    if [[ $# -gt 0 ]]; then
        exec "$@"
    fi

    # --- Initialize variables ---
    PUID="${PUID:-$DEFAULT_PUID}"
    PGID="${PGID:-$DEFAULT_PGID}"
    PUID="$(trim "$PUID")"
    PGID="$(trim "$PGID")"

    PORT="${PORT:-$DEFAULT_PORT}"
    INTERNAL_PORT="${INTERNAL_PORT:-$DEFAULT_INTERNAL_PORT}"
    PROTOCOL="${PROTOCOL:-$DEFAULT_PROTOCOL}"
    CORS="${CORS:-}"
    DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"

    PORT="$(validate_port "PORT" "$PORT" "$DEFAULT_PORT")"
    INTERNAL_PORT="$(validate_port "INTERNAL_PORT" "$INTERNAL_PORT" "$DEFAULT_INTERNAL_PORT")"

    validate_api_key
    validate_cors

    # --- First run: UID/GID setup ---
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$FIRST_RUN_FILE" ]]; then
        handle_first_run
    fi

    # --- Ensure data directory ---
    mkdir -p "$DATA_DIR"
    mkdir -p "$REGISTRY_DIR"
    chown "${PUID}:${PGID}" "$DATA_DIR" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "$REGISTRY_DIR" 2>/dev/null || true
    for subdir in "$DATA_DIR"/*/; do
        if [[ -d "$subdir" ]]; then
            chown "${PUID}:${PGID}" "$subdir" 2>/dev/null || true
        fi
    done

    # --- Mark all mounted repos as safe for git ---
    git config --global --add safe.directory '*'
    if [ "$(id -u)" -eq 0 ]; then
        gosu node git config --global --add safe.directory '*'
    fi

    # --- Generate HAProxy config ---
    generate_haproxy_config

    # --- Signal handling ---
    trap shutdown INT TERM EXIT

    # --- GitNexus analysis phase ---
    echo "=========================================="
    echo "GitNexus Gateway Analysis Phase"
    echo "Data directory: ${DATA_DIR}"
    echo "=========================================="

    touch "$ANALYSIS_LOCK"
    run_gitnexus_clean
    run_gitnexus_analyze "$DATA_DIR"
    run_gitnexus_wiki "$DATA_DIR"
    rm -f "$ANALYSIS_LOCK"

    # --- Start services ---
    echo "=========================================="
    echo "Starting GitNexus Gateway Services"
    echo "=========================================="

    start_mcp_server
    start_haproxy

    if [[ -n "$API_KEY" ]]; then
        echo "API key authentication enabled"
    else
        echo "API key authentication disabled"
    fi

    echo "=========================================="
    echo "GitNexus Gateway: port ${PORT} (${PROTOCOL_DISPLAY})"
    echo "=========================================="

    # Wait for any child process to exit
    local pids=("$MCP_PID" "$HAPROXY_PID")
    wait -n "${pids[@]}"
}

main "$@"
