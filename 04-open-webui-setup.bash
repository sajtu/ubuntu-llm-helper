#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# AI host setup — phase 4: Open WebUI
#
# Installs Open WebUI using either:
#   - Docker, managed by open-webui.service; or
#   - an isolated native Python virtual environment, also managed by systemd.
#
# Open WebUI always listens on 127.0.0.1. Network exposure and reverse proxies
# are deliberately handled by phase 05, after this phase has created the first
# administrator and successfully certified the local service.
###############################################################################

PROGRAM_NAME="${0##*/}"
STATE_DIR='/var/lib/ai-host-setup'
OLLAMA_STATE="$STATE_DIR/ollama.conf"
PROVIDER_DIR="$STATE_DIR/providers.d"
OLLAMA_PROVIDER="$PROVIDER_DIR/ollama.conf"
STATE_FILE="$STATE_DIR/open-webui.conf"

SERVICE_NAME='open-webui.service'
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
ENV_DIR='/etc/open-webui'
SERVICE_ENV="$ENV_DIR/open-webui.env"

CONTAINER_NAME='open-webui'
VOLUME_NAME='open-webui'
NATIVE_USER='open-webui'
NATIVE_GROUP='open-webui'
NATIVE_ROOT='/opt/open-webui'
NATIVE_VENV="$NATIVE_ROOT/venv"
NATIVE_DATA='/var/lib/open-webui'

OPENWEBUI_VERSION="${OPENWEBUI_VERSION:-v0.9.5}"
OPENWEBUI_PYTHON_VERSION="${OPENWEBUI_VERSION#v}"
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:$OPENWEBUI_VERSION"
OPENWEBUI_PORT='8080'
OPENWEBUI_URL=''

ACTION='none'
ACTION_SET='no'
RUNTIME=''
MODE_EXPLICIT='no'
FACTORY_RESET='no'
SYSTEMD_ACTION=''
SERVICE_ACTION=''

OLLAMA_BASE_URL=''
CERT_MODEL=''
ADMIN_SETUP='pending'
MODEL_CERTIFIED='no'
CHAT_CERTIFIED='no'
TEMP_DIR=''
ADMIN_NAME="${AI_OPENWEBUI_ADMIN_NAME:-}"
ADMIN_EMAIL="${AI_OPENWEBUI_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AI_OPENWEBUI_ADMIN_PASSWORD:-}"
ADMIN_PASSWORD_CONFIRM=''
AUTH_TOKEN=''

# Keep an automation-supplied password in a shell variable, but do not export
# it to apt, pip, Docker, systemctl, or other child processes.
unset AI_OPENWEBUI_ADMIN_PASSWORD

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

info() {
    printf '\n== %s ==\n' "$*"
}

usage() {
    cat <<EOF
Usage:
  To install:
     sudo ./$PROGRAM_NAME --mode docker|native [--factoryreset]

  Post Install Options:
     sudo ./$PROGRAM_NAME --check
     sudo ./$PROGRAM_NAME --certify
     sudo ./$PROGRAM_NAME --systemd enable|disable|status
     sudo ./$PROGRAM_NAME --service stop|start|restart

Setup/install options:
  --mode docker|native      Install using the either Docker or Native mode.

  --factoryreset            Delete the project-managed Open WebUI instance and
                            all Open WebUI data, then install again from scratch
                            (these three switches are equivalent)

Post-install operations (each must be used by itself):
  --check                    Verify configuration, services, and health
  --certify                  Re-run administrator, discovery, and chat checks
  --systemd enable|disable|status
                             Configure or inspect systemd boot registration
  --service stop|start|restart
                             Control the running Open WebUI service
  -h, --help                 Show this help

Environment variables:
  OPENWEBUI_VERSION             Release/image tag (default: v0.9.5)
  AI_OPENWEBUI_ADMIN_NAME       Administrator display name (default: Admin)
  AI_OPENWEBUI_ADMIN_EMAIL      New/existing administrator email
  AI_OPENWEBUI_ADMIN_PASSWORD   New/existing administrator password

Examples:
  sudo ./$PROGRAM_NAME --mode docker
  sudo ./$PROGRAM_NAME --mode native
  sudo ./$PROGRAM_NAME --systemd enable
  sudo ./$PROGRAM_NAME --systemd status
  sudo ./$PROGRAM_NAME --service restart
  sudo ./$PROGRAM_NAME --check
  sudo ./$PROGRAM_NAME --certify

The native path does not install, require, or invoke Docker. This phase remains
loopback-only. Run 05-caddy-setup.bash afterward for optional LAN access.
EOF
}

secure_remove() {
    local path="${1:-}"
    [[ -n "$path" && -f "$path" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -u -- "$path" 2>/dev/null || rm -f -- "$path"
    else
        rm -f -- "$path"
    fi
}

cleanup() {
    local exit_status=$?

    if [[ "$TEMP_DIR" == /run/ai-open-webui.* && -d "$TEMP_DIR" ]]; then
        secure_remove "$TEMP_DIR/signin.json"
        secure_remove "$TEMP_DIR/signin-response.json"
        secure_remove "$TEMP_DIR/signup.json"
        secure_remove "$TEMP_DIR/signup-response.json"
        secure_remove "$TEMP_DIR/models.json"
        secure_remove "$TEMP_DIR/chat-request.json"
        secure_remove "$TEMP_DIR/chat-response.json"
        rmdir "$TEMP_DIR" 2>/dev/null || true
    fi

    unset ADMIN_PASSWORD ADMIN_PASSWORD_CONFIRM AUTH_TOKEN
    return "$exit_status"
}

trap cleanup EXIT

set_action() {
    local requested="$1"
    [[ "$ACTION_SET" == 'no' ]] || die "Specify only one post-install operation."
    ACTION="$requested"
    ACTION_SET='yes'
}

if (( $# == 0 )); then
    usage
    exit 0
fi

while (( $# > 0 )); do
    case "$1" in
        --mode|--installmode|--install)
            (( $# >= 2 )) || die "$1 requires docker or native."
            [[ "$MODE_EXPLICIT" == 'no' ]] ||
                die "Specify only one installation-mode switch."
            RUNTIME="$2"
            MODE_EXPLICIT='yes'
            shift 2
            ;;
        --factoryreset|--delete|--fromscratch)
            [[ "$FACTORY_RESET" == 'no' ]] ||
                die "Specify only one factory-reset switch."
            FACTORY_RESET='yes'
            shift
            ;;
        --systemd)
            (( $# >= 2 )) || die "--systemd requires enable, disable, or status."
            [[ -z "$SYSTEMD_ACTION" ]] || die "Specify --systemd only once."
            SYSTEMD_ACTION="$2"
            shift 2
            ;;
        --service)
            (( $# >= 2 )) || die "--service requires start, stop, or restart."
            [[ -z "$SERVICE_ACTION" ]] || die "Specify --service only once."
            SERVICE_ACTION="$2"
            shift 2
            ;;
        --check|--certify)
            set_action "${1#--}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ "$RUNTIME" == '' || "$RUNTIME" == 'docker' || "$RUNTIME" == 'native' ]] ||
    die "The installation mode must be docker or native."
[[ "$SYSTEMD_ACTION" == '' || "$SYSTEMD_ACTION" == 'enable' ||
   "$SYSTEMD_ACTION" == 'disable' || "$SYSTEMD_ACTION" == 'status' ]] ||
    die "--systemd must be enable, disable, or status."
[[ "$SERVICE_ACTION" == '' || "$SERVICE_ACTION" == 'start' ||
   "$SERVICE_ACTION" == 'stop' || "$SERVICE_ACTION" == 'restart' ]] ||
    die "--service must be start, stop, or restart."

if [[ "$FACTORY_RESET" == 'yes' && "$MODE_EXPLICIT" == 'no' ]]; then
    die "Factory reset requires --mode, --installmode, or --install."
fi

if [[ "$MODE_EXPLICIT" == 'yes' ]]; then
    [[ "$ACTION_SET" == 'no' && -z "$SYSTEMD_ACTION" && -z "$SERVICE_ACTION" ]] ||
        die "Installation mode cannot be combined with a post-install operation."
    ACTION='install'
elif [[ -n "$SYSTEMD_ACTION" || -n "$SERVICE_ACTION" ]]; then
    [[ "$ACTION_SET" == 'no' && "$FACTORY_RESET" == 'no' ]] ||
        die "Post-install management switches cannot be combined with other options."
    [[ -z "$SYSTEMD_ACTION" || -z "$SERVICE_ACTION" ]] ||
        die "--systemd and --service cannot be used together."
    if [[ -n "$SYSTEMD_ACTION" ]]; then
        ACTION='systemd'
    else
        ACTION='service'
    fi
elif [[ "$ACTION_SET" == 'yes' ]]; then
    [[ "$FACTORY_RESET" == 'no' ]] ||
        die "Factory reset requires an installation-mode switch."
else
    die "No action was selected. Use an installation-mode switch or --help."
fi

[[ "$OPENWEBUI_PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $OPENWEBUI_PORT"
(( OPENWEBUI_PORT >= 1 && OPENWEBUI_PORT <= 65535 )) ||
    die "Port must be between 1 and 65535."
[[ "$OPENWEBUI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "OPENWEBUI_VERSION must be a release such as v0.9.5."

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."
[[ -d /run/systemd/system ]] || die "This host is not running systemd."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == 'ubuntu' ]] || die "This phase currently supports Ubuntu only."
[[ "${VERSION_ID:-}" == '24.04' ]] ||
    die "This release is not yet supported: ${PRETTY_NAME:-Ubuntu ${VERSION_ID:-unknown}}."
[[ "$(dpkg --print-architecture)" == 'amd64' ]] ||
    die "This phase currently supports Ubuntu amd64 only."

read_conf_value() {
    local file="$1"
    local key="$2"

    awk -F= -v wanted="$key" '
        $1 == wanted {
            value=substr($0, index($0, "=") + 1)
            if (value ~ /^\047.*\047$/) {
                value=substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$file"
}

factory_reset_openwebui() {
    local old_runtime=''
    local managed=''
    local project_verified='no'

    info "Factory-resetting the project-managed Open WebUI installation"
    warn "This permanently deletes Open WebUI accounts, settings, conversations, uploads, and other Open WebUI application data."
    printf 'Ollama models, Ollama, GPU drivers, Docker itself, and phase 05 Caddy configuration are not removed.\n'

    if [[ -r "$STATE_FILE" ]]; then
        [[ "$(read_conf_value "$STATE_FILE" PHASE)" == 'open-webui' ]] ||
            die "Refusing factory reset because $STATE_FILE is not valid project state."
        old_runtime="$(read_conf_value "$STATE_FILE" RUNTIME)"
        [[ "$old_runtime" == 'docker' || "$old_runtime" == 'native' ]] ||
            die "Refusing factory reset because the recorded runtime is invalid."
        project_verified='yes'
    elif [[ -e "$SERVICE_FILE" ]]; then
        if grep -Fq 'ai-host-setup.phase=open-webui' "$SERVICE_FILE" ||
           grep -Fq "$NATIVE_VENV/bin/open-webui serve" "$SERVICE_FILE"; then
            project_verified='yes'
            warn "The service has no state file, but its project-managed unit signature was verified."
        else
            die "$SERVICE_FILE exists without project state; refusing to delete an unverified installation."
        fi
    else
        printf 'No prior project-managed Open WebUI state was found; continuing with a fresh installation.\n'
    fi

    if [[ "$project_verified" == 'yes' ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    # Remove any project-labelled Docker instance, including a leftover from a
    # prior runtime choice. Never delete an unlabelled container or volume.
    if command -v docker >/dev/null 2>&1; then
        systemctl start docker
        docker info >/dev/null 2>&1 ||
            die "The Docker daemon is unavailable; the Open WebUI data volume was not deleted."
        if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            managed="$(docker inspect -f '{{index .Config.Labels "ai-host-setup.managed"}}' \
                "$CONTAINER_NAME" 2>/dev/null || true)"
            [[ "$managed" == 'true' ]] ||
                die "Refusing to delete the unowned Docker container: $CONTAINER_NAME"
            docker rm -f "$CONTAINER_NAME" >/dev/null
        fi

        if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
            managed="$(docker volume inspect -f '{{index .Labels "ai-host-setup.managed"}}' \
                "$VOLUME_NAME" 2>/dev/null || true)"
            [[ "$managed" == 'true' ]] ||
                die "Refusing to delete the unowned Docker volume: $VOLUME_NAME"
            docker volume rm "$VOLUME_NAME" >/dev/null
        fi
    fi

    # These fixed paths are created only by this project. Require verified
    # project state or a verified service signature before deleting them.
    if [[ "$project_verified" == 'yes' ]]; then
        rm -rf -- "$NATIVE_ROOT" "$NATIVE_DATA"
    elif [[ -e "$NATIVE_ROOT" || -e "$NATIVE_DATA" ]]; then
        die "Native Open WebUI paths exist without verifiable project ownership; refusing to delete them."
    fi

    rm -f -- "$SERVICE_FILE" "$SERVICE_ENV" "$STATE_FILE"
    rmdir "$ENV_DIR" 2>/dev/null || true
    systemctl daemon-reload

    ADMIN_SETUP='pending'
    MODEL_CERTIFIED='no'
    CHAT_CERTIFIED='no'
    printf 'Previous project-managed Open WebUI instance removed.\n'
}

if [[ "$FACTORY_RESET" == 'yes' ]]; then
    factory_reset_openwebui
fi

load_existing_state() {
    [[ -r "$STATE_FILE" ]] || die "Open WebUI is not installed by this project."
    [[ "$(read_conf_value "$STATE_FILE" PHASE)" == 'open-webui' ]] ||
        die "The phase state file is invalid: $STATE_FILE"

    RUNTIME="$(read_conf_value "$STATE_FILE" RUNTIME)"
    ADMIN_SETUP="$(read_conf_value "$STATE_FILE" ADMIN_SETUP)"
    MODEL_CERTIFIED="$(read_conf_value "$STATE_FILE" MODEL_DISCOVERY_CERTIFIED)"
    CHAT_CERTIFIED="$(read_conf_value "$STATE_FILE" CHAT_CERTIFIED)"

    OPENWEBUI_PORT="$(read_conf_value "$STATE_FILE" OPENWEBUI_PORT)"

    [[ "$RUNTIME" == 'docker' || "$RUNTIME" == 'native' ]] ||
        die "The recorded Open WebUI runtime is invalid."
}

if [[ "$ACTION" != 'install' ]]; then
    load_existing_state
elif [[ -r "$STATE_FILE" ]]; then
    existing_runtime="$(read_conf_value "$STATE_FILE" RUNTIME)"

    if [[ -n "$RUNTIME" && "$RUNTIME" != "$existing_runtime" ]]; then
        die "This host already has a $existing_runtime deployment. Automatic runtime migration is not supported."
    fi

    load_existing_state
fi

OPENWEBUI_URL="http://127.0.0.1:$OPENWEBUI_PORT"

write_ollama_provider() {
    mkdir -p "$PROVIDER_DIR"
    chmod 0755 "$PROVIDER_DIR"

    {
        printf 'SCHEMA_VERSION=%q\n' '1'
        printf 'PROVIDER_ID=%q\n' 'ollama'
        printf 'PROVIDER_NAME=%q\n' 'Ollama'
        printf 'PROTOCOL=%q\n' 'ollama'
        printf 'BASE_URL=%q\n' "$OLLAMA_BASE_URL"
        printf 'MODEL_LIST_PATH=%q\n' '/api/tags'
        printf 'SERVICE_NAME=%q\n' 'ollama.service'
        printf 'MANAGED_BY=%q\n' "$PROGRAM_NAME"
        printf 'REGISTERED_AT=%q\n' "$(date --iso-8601=seconds)"
    } > "$OLLAMA_PROVIDER"
    chmod 0644 "$OLLAMA_PROVIDER"
}

load_ollama_provider() {
    local ollama_host

    [[ -r "$OLLAMA_STATE" ]] ||
        die "Ollama phase state is missing. Run 03-ollama-setup.bash first."
    [[ "$(read_conf_value "$OLLAMA_STATE" PHASE)" == 'ollama' ]] ||
        die "The Ollama phase state is invalid: $OLLAMA_STATE"

    CERT_MODEL="$(read_conf_value "$OLLAMA_STATE" CERT_MODEL)"
    [[ -n "$CERT_MODEL" ]] || CERT_MODEL='qwen3:0.6b'

    if [[ -r "$OLLAMA_PROVIDER" ]]; then
        [[ "$(read_conf_value "$OLLAMA_PROVIDER" PROTOCOL)" == 'ollama' ]] ||
            die "The Ollama provider record has an unsupported protocol."
        OLLAMA_BASE_URL="$(read_conf_value "$OLLAMA_PROVIDER" BASE_URL)"
    else
        ollama_host="$(read_conf_value "$OLLAMA_STATE" OLLAMA_HOST)"
        [[ -n "$ollama_host" ]] || die "Ollama's API address is missing."
        OLLAMA_BASE_URL="http://$ollama_host"
        [[ "$ACTION" == 'install' ]] && write_ollama_provider
    fi

    [[ "$OLLAMA_BASE_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] ||
        die "Ollama must use a loopback HTTP endpoint; found: $OLLAMA_BASE_URL"
}

verify_ollama() {
    local tags_file

    command -v curl >/dev/null 2>&1 || die "curl is unavailable."
    command -v jq >/dev/null 2>&1 || die "jq is unavailable."
    tags_file="$(mktemp /run/ollama-tags.XXXXXX)"

    if ! curl --fail --silent --show-error --max-time 15 \
        --output "$tags_file" "$OLLAMA_BASE_URL/api/tags"; then
        rm -f -- "$tags_file"
        die "The recorded Ollama API is unavailable: $OLLAMA_BASE_URL"
    fi

    if ! jq -e --arg model "$CERT_MODEL" '
        [.models[]? | (.name // .model // "")]
        | any(. == $model or startswith($model + ":"))
    ' "$tags_file" >/dev/null; then
        rm -f -- "$tags_file"
        die "The Ollama certification model is unavailable: $CERT_MODEL"
    fi
    rm -f -- "$tags_file"
}

printf 'Operating system:  %s\n' "${PRETTY_NAME:-Ubuntu}"
printf 'Architecture:      %s\n' "$(dpkg --print-architecture)"
printf 'Open WebUI version:%s\n' " $OPENWEBUI_VERSION"
if [[ "$ACTION" != 'install' ]]; then
    printf 'Open WebUI port:   %s\n' "$OPENWEBUI_PORT"
fi

if [[ "$ACTION" == 'install' || "$ACTION" == 'check' || "$ACTION" == 'certify' ]]; then
    load_ollama_provider
    printf 'Ollama provider:   %s\n' "$OLLAMA_BASE_URL"
    printf 'Test model:        %s\n' "$CERT_MODEL"
fi

choose_install_options() {
    local numeric_port
    local requested_port

    [[ "$RUNTIME" == 'docker' || "$RUNTIME" == 'native' ]] ||
        die "Installation requires --mode, --installmode, or --install with docker or native."

    if [[ -t 0 ]]; then
        info "Configure the Open WebUI listener"
        while true; do
            read -r -p "Open WebUI loopback port [$OPENWEBUI_PORT]: " requested_port
            requested_port="${requested_port:-$OPENWEBUI_PORT}"

            if [[ ! "$requested_port" =~ ^[0-9]{1,5}$ ]]; then
                warn "Enter a TCP port between 1 and 65535."
                continue
            fi

            numeric_port=$((10#$requested_port))
            if (( numeric_port < 1 || numeric_port > 65535 )); then
                warn "Enter a TCP port between 1 and 65535."
                continue
            fi

            OPENWEBUI_PORT="$numeric_port"
            break
        done
    else
        printf 'Non-interactive installation: using Open WebUI port %s.\n' \
            "$OPENWEBUI_PORT"
    fi

    OPENWEBUI_URL="http://127.0.0.1:$OPENWEBUI_PORT"
}

write_service_environment() {
    mkdir -p "$ENV_DIR"
    chmod 0755 "$ENV_DIR"

    {
        printf 'HOST=127.0.0.1\n'
        printf 'PORT=%s\n' "$OPENWEBUI_PORT"
        printf 'WEBUI_AUTH=True\n'
        printf 'ENABLE_SIGNUP=True\n'
        printf 'OLLAMA_BASE_URL=%s\n' "$OLLAMA_BASE_URL"
        printf 'ENABLE_OLLAMA_API=True\n'
        printf 'AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST=3\n'
        if [[ "$RUNTIME" == 'native' ]]; then
            printf 'DATA_DIR=%s\n' "$NATIVE_DATA/data"
        fi
    } > "$SERVICE_ENV"
    chmod 0644 "$SERVICE_ENV"
}

install_docker_runtime() {
    info "Installing the Docker runtime"
    if ! command -v docker >/dev/null 2>&1; then
        apt-get install -y docker.io
    else
        printf 'Reusing the installed Docker Engine.\n'
    fi
    systemctl enable --now docker
    docker info >/dev/null 2>&1 || die "The Docker daemon is unavailable."

    docker pull "$OPENWEBUI_IMAGE"
    docker image inspect "$OPENWEBUI_IMAGE" >/dev/null ||
        die "The Open WebUI image is unavailable after download."

    if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        managed="$(docker inspect -f '{{index .Config.Labels "ai-host-setup.managed"}}' \
            "$CONTAINER_NAME" 2>/dev/null || true)"
        [[ "$managed" == 'true' ]] ||
            die "A container named $CONTAINER_NAME exists but is not managed by this project."
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi

    if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        managed="$(docker volume inspect -f '{{index .Labels "ai-host-setup.managed"}}' \
            "$VOLUME_NAME" 2>/dev/null || true)"
        [[ "$managed" == 'true' ]] ||
            die "A volume named $VOLUME_NAME exists but is not managed by this project."
    else
        docker volume create \
            --label 'ai-host-setup.managed=true' \
            --label 'ai-host-setup.phase=open-webui' \
            "$VOLUME_NAME" >/dev/null
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Open WebUI (Docker runtime)
Requires=docker.service
After=docker.service network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f $CONTAINER_NAME
ExecStart=/usr/bin/docker run --rm --name $CONTAINER_NAME --label ai-host-setup.managed=true --label ai-host-setup.phase=open-webui --network host --volume $VOLUME_NAME:/app/backend/data --env-file $SERVICE_ENV $OPENWEBUI_IMAGE
ExecStop=-/usr/bin/docker stop --time 30 $CONTAINER_NAME
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0
TimeoutStopSec=45s

[Install]
WantedBy=multi-user.target
EOF
}

install_native_runtime() {
    info "Installing the native Python runtime"
    apt-get install -y python3 python3-venv python3-pip

    if ! getent group "$NATIVE_GROUP" >/dev/null; then
        groupadd --system "$NATIVE_GROUP"
    fi
    if ! id "$NATIVE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$NATIVE_GROUP" --home-dir "$NATIVE_DATA" \
            --shell /usr/sbin/nologin "$NATIVE_USER"
    fi

    install -d -o root -g root -m 0755 "$NATIVE_ROOT"
    install -d -o "$NATIVE_USER" -g "$NATIVE_GROUP" -m 0750 "$NATIVE_DATA"
    install -d -o "$NATIVE_USER" -g "$NATIVE_GROUP" -m 0750 "$NATIVE_DATA/data"

    if [[ ! -x "$NATIVE_VENV/bin/python" ]]; then
        python3 -m venv "$NATIVE_VENV"
    fi

    "$NATIVE_VENV/bin/python" -m pip install --disable-pip-version-check \
        --upgrade pip wheel
    "$NATIVE_VENV/bin/python" -m pip install --disable-pip-version-check \
        "open-webui==$OPENWEBUI_PYTHON_VERSION"
    [[ -x "$NATIVE_VENV/bin/open-webui" ]] ||
        die "The native Open WebUI executable was not installed."

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Open WebUI (native Python runtime)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=$NATIVE_USER
Group=$NATIVE_GROUP
WorkingDirectory=$NATIVE_DATA
EnvironmentFile=$SERVICE_ENV
ExecStart=$NATIVE_VENV/bin/open-webui serve
Restart=on-failure
RestartSec=5s
TimeoutStartSec=180s
TimeoutStopSec=45s

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_openwebui() {
    local attempt
    for attempt in {1..90}; do
        if curl --fail --silent --show-error --max-time 5 \
            "$OPENWEBUI_URL/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    journalctl -u "$SERVICE_NAME" -n 150 --no-pager 2>&1 || true
    die "Open WebUI did not become healthy within three minutes."
}

record_state() {
    local admin_setup="$1"
    local model_certified="$2"
    local chat_certified="$3"
    local certified_at=''
    local configured_at

    mkdir -p "$STATE_DIR"
    chmod 0755 "$STATE_DIR"
    configured_at="$(date --iso-8601=seconds)"
    [[ "$chat_certified" == 'yes' ]] && certified_at="$configured_at"

    {
        printf 'PHASE=%q\n' 'open-webui'
        printf 'RUNTIME=%q\n' "$RUNTIME"
        printf 'SERVICE_NAME=%q\n' "$SERVICE_NAME"
        printf 'OPENWEBUI_VERSION=%q\n' "$OPENWEBUI_VERSION"
        printf 'OPENWEBUI_PORT=%q\n' "$OPENWEBUI_PORT"
        printf 'LISTEN_ADDRESS=%q\n' '127.0.0.1'
        printf 'LISTEN_SCOPE=%q\n' 'loopback'
        printf 'OLLAMA_BASE_URL=%q\n' "$OLLAMA_BASE_URL"
        printf 'CERT_MODEL=%q\n' "$CERT_MODEL"
        printf 'ADMIN_SETUP=%q\n' "$admin_setup"
        printf 'MODEL_DISCOVERY_CERTIFIED=%q\n' "$model_certified"
        printf 'CHAT_CERTIFIED=%q\n' "$chat_certified"
        printf 'CERTIFIED_AT=%q\n' "$certified_at"
        printf 'CONFIGURED_AT=%q\n' "$configured_at"
    } > "$STATE_FILE"
    chmod 0644 "$STATE_FILE"
}

show_status() {
    local active='no'
    local enabled='no'

    systemctl is-active --quiet "$SERVICE_NAME" && active='yes'
    systemctl is-enabled --quiet "$SERVICE_NAME" && enabled='yes'

    printf 'Runtime:           %s\n' "$RUNTIME"
    printf 'Service:           %s\n' "$SERVICE_NAME"
    printf 'Service active:    %s\n' "$active"
    printf 'Starts at boot:    %s\n' "$enabled"
    printf 'Loopback URL:      %s\n' "$OPENWEBUI_URL"
    printf 'Admin setup:       %s\n' "$ADMIN_SETUP"
    printf 'Model certified:   %s\n' "$MODEL_CERTIFIED"
    printf 'Chat certified:    %s\n' "$CHAT_CERTIFIED"
    printf 'Network exposure:  loopback only\n'
}

verify_installation() {
    [[ -f "$SERVICE_FILE" ]] || die "$SERVICE_FILE is missing."
    systemctl is-active --quiet "$SERVICE_NAME" || die "$SERVICE_NAME is not active."
    curl --fail --silent --show-error --max-time 15 \
        "$OPENWEBUI_URL/health" >/dev/null || die "Open WebUI is unhealthy."

    if [[ "$RUNTIME" == 'docker' ]]; then
        command -v docker >/dev/null 2>&1 || die "Docker is unavailable."
        docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 ||
            die "The Open WebUI container is unavailable."
    else
        [[ -x "$NATIVE_VENV/bin/open-webui" ]] ||
            die "The native Open WebUI executable is unavailable."
    fi

}

manage_services() {
    if [[ "$ACTION" == 'systemd' ]]; then
        case "$SYSTEMD_ACTION" in
            enable)
                systemctl enable "$SERVICE_NAME"
                ;;
            disable)
                systemctl disable "$SERVICE_NAME"
                ;;
            status)
                show_status
                printf '\n'
                systemctl status "$SERVICE_NAME" --no-pager || true
                return 0
                ;;
        esac
    else
        case "$SERVICE_ACTION" in
            start)
                systemctl start "$SERVICE_NAME"
                wait_for_openwebui
                ;;
            stop)
                systemctl stop "$SERVICE_NAME"
                ;;
            restart)
                systemctl restart "$SERVICE_NAME"
                wait_for_openwebui
                ;;
        esac
    fi

    show_status
}

prepare_credential_temp_dir() {
    if [[ -z "$TEMP_DIR" ]]; then
        TEMP_DIR="$(mktemp -d /run/ai-open-webui.XXXXXX)"
        chmod 0700 "$TEMP_DIR"
    fi
}

validate_admin_password() {
    local character_count
    local password_bytes

    character_count="${#ADMIN_PASSWORD}"
    password_bytes="$(LC_ALL=C printf '%s' "$ADMIN_PASSWORD" | wc -c)"
    password_bytes="${password_bytes//[[:space:]]/}"

    (( character_count >= 8 )) || return 1
    (( password_bytes <= 72 )) || return 1
    [[ "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* ]]
}

collect_new_admin_credentials() {
    info "Configure the Open WebUI administrator before installation"

    if [[ -z "$ADMIN_NAME" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Administrator display name [Admin]: " ADMIN_NAME
            ADMIN_NAME="${ADMIN_NAME:-Admin}"
        else
            ADMIN_NAME='Admin'
        fi
    else
        printf 'Administrator name:  %s\n' "$ADMIN_NAME"
    fi
    [[ "$ADMIN_NAME" != *$'\n'* && "$ADMIN_NAME" != *$'\r'* ]] ||
        die "The administrator name cannot contain a newline."

    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -r -p "Administrator email: " ADMIN_EMAIL
        if [[ ! "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
            warn "Enter a valid administrator email address."
            ADMIN_EMAIL=''
        fi
    done
    [[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
        die "AI_OPENWEBUI_ADMIN_EMAIL is not a valid email address."

    if [[ -n "$ADMIN_PASSWORD" ]]; then
        validate_admin_password ||
            die "AI_OPENWEBUI_ADMIN_PASSWORD must contain at least 8 characters, use no more than 72 UTF-8 bytes, and contain no newline."
    else
        while true; do
            read -r -s -p "Administrator password (8+ characters; 72-byte maximum): " ADMIN_PASSWORD
            printf '\n'
            read -r -s -p "Confirm administrator password: " ADMIN_PASSWORD_CONFIRM
            printf '\n'

            if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
                warn "The passwords did not match. Please try again."
                ADMIN_PASSWORD=''
                ADMIN_PASSWORD_CONFIRM=''
                continue
            fi
            if ! validate_admin_password; then
                warn "Use at least 8 characters, no more than 72 UTF-8 bytes, and no newline."
                ADMIN_PASSWORD=''
                ADMIN_PASSWORD_CONFIRM=''
                continue
            fi
            break
        done
    fi

    unset ADMIN_PASSWORD_CONFIRM
    printf 'Administrator credentials accepted. Installation can now run unattended.\n'
}

collect_existing_admin_credentials() {
    info "Collecting the existing Open WebUI administrator credentials"
    if [[ -z "$ADMIN_EMAIL" ]]; then
        read -r -p "Administrator email: " ADMIN_EMAIL
    fi
    [[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
        die "Enter a valid administrator email address."

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        read -r -s -p "Administrator password: " ADMIN_PASSWORD
        printf '\n'
    fi
    [[ -n "$ADMIN_PASSWORD" ]] || die "The administrator password is empty."

    prepare_credential_temp_dir
}

create_initial_admin() {
    local http_status
    local signup_error

    prepare_credential_temp_dir
    info "Creating the initial Open WebUI administrator"

    # Recovery path: the prior run may have created the administrator and then
    # failed during a later certification step. Verify before attempting signup.
    printf '%s' "$ADMIN_PASSWORD" | jq -Rs --arg email "$ADMIN_EMAIL" \
        '{email: $email, password: .}' > "$TEMP_DIR/signin.json"
    http_status="$(curl --silent --show-error --max-time 30 \
        --header 'Content-Type: application/json' \
        --data-binary "@$TEMP_DIR/signin.json" \
        --output "$TEMP_DIR/signin-response.json" \
        --write-out '%{http_code}' \
        "$OPENWEBUI_URL/api/v1/auths/signin")"

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]] &&
       [[ "$(jq -r '.role // empty' "$TEMP_DIR/signin-response.json")" == 'admin' ]]; then
        printf 'Existing administrator verified: %s\n' "$ADMIN_EMAIL"
        return 0
    fi

    printf '%s' "$ADMIN_PASSWORD" | jq -Rs \
        --arg name "$ADMIN_NAME" \
        --arg email "$ADMIN_EMAIL" \
        '{name: $name, email: $email, password: .}' \
        > "$TEMP_DIR/signup.json"

    http_status="$(curl --silent --show-error --max-time 30 \
        --header 'Content-Type: application/json' \
        --data-binary "@$TEMP_DIR/signup.json" \
        --output "$TEMP_DIR/signup-response.json" \
        --write-out '%{http_code}' \
        "$OPENWEBUI_URL/api/v1/auths/signup")"

    if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        signup_error="$(jq -r '.detail // "unknown signup error"' \
            "$TEMP_DIR/signup-response.json" 2>/dev/null || true)"
        die "Open WebUI could not create the initial administrator (HTTP $http_status): $signup_error"
    fi

    [[ "$(jq -r '.role // empty' "$TEMP_DIR/signup-response.json")" == 'admin' ]] ||
        die "The initial Open WebUI account was created but was not assigned the administrator role."

    secure_remove "$TEMP_DIR/signup.json"
    printf 'Initial administrator: %s <%s>\n' "$ADMIN_NAME" "$ADMIN_EMAIL"
}

certify_openwebui() {
    info "Authenticating the Open WebUI administrator"
    printf '%s' "$ADMIN_PASSWORD" | jq -Rs --arg email "$ADMIN_EMAIL" \
        '{email: $email, password: .}' > "$TEMP_DIR/signin.json"

    if ! curl --fail --silent --show-error --max-time 30 \
        --header 'Content-Type: application/json' \
        --data-binary "@$TEMP_DIR/signin.json" \
        --output "$TEMP_DIR/signin-response.json" \
        "$OPENWEBUI_URL/api/v1/auths/signin"; then
        die "Open WebUI rejected the credentials. Create the first browser account before --certify."
    fi

    AUTH_TOKEN="$(jq -r '.token // empty' "$TEMP_DIR/signin-response.json")"
    [[ -n "$AUTH_TOKEN" ]] || die "Open WebUI returned no authentication token."
    [[ "$(jq -r '.role // empty' "$TEMP_DIR/signin-response.json")" == 'admin' ]] ||
        die "The supplied Open WebUI account is not an administrator."

    info "Verifying Ollama model discovery through Open WebUI"
    curl --fail --silent --show-error --max-time 30 \
        --header "Authorization: Bearer $AUTH_TOKEN" \
        --output "$TEMP_DIR/models.json" \
        "$OPENWEBUI_URL/api/models"

    jq -e --arg model "$CERT_MODEL" '
        [.. | objects | .id? // empty]
        | any(. == $model or startswith($model + ":"))
    ' "$TEMP_DIR/models.json" >/dev/null ||
        die "Open WebUI did not discover the Ollama model $CERT_MODEL."

    info "Certifying chat through Open WebUI and Ollama"
    jq -n --arg model "$CERT_MODEL" '
        {
            model: $model,
            messages: [
                {role: "user", content: "Reply exactly: Open WebUI certification passed"}
            ],
            stream: false,
            think: false,
            options: {num_predict: 24}
        }
    ' > "$TEMP_DIR/chat-request.json"

    if ! curl --fail --silent --show-error --max-time 300 \
        --header "Authorization: Bearer $AUTH_TOKEN" \
        --header 'Content-Type: application/json' \
        --data-binary "@$TEMP_DIR/chat-request.json" \
        --output "$TEMP_DIR/chat-response.json" \
        "$OPENWEBUI_URL/ollama/api/chat"; then
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager 2>&1 || true
        die "The authenticated Open WebUI-to-Ollama chat certification request failed."
    fi

    jq -e '(.message.content // "") | length > 0' \
        "$TEMP_DIR/chat-response.json" >/dev/null ||
        die "Open WebUI returned no chat response from Ollama."
    printf 'Model response: %s\n' \
        "$(jq -r '.message.content' "$TEMP_DIR/chat-response.json")"
}

verify_local_page() {
    info "Verifying the local Open WebUI page"
    curl --fail --silent --show-error --max-time 30 \
        --output /dev/null "$OPENWEBUI_URL/" ||
        die "Open WebUI is healthy, but its local page did not load from $OPENWEBUI_URL/."
    printf 'Local page loaded successfully: %s/\n' "$OPENWEBUI_URL"
}

case "$ACTION" in
    systemd|service)
        manage_services
        exit 0
        ;;
    check)
        verify_ollama
        verify_installation
        verify_local_page
        show_status
        exit 0
        ;;
esac

if [[ "$ACTION" == 'certify' ]]; then
    verify_ollama
    verify_installation
    collect_existing_admin_credentials
    certify_openwebui
    ADMIN_SETUP='complete'
    MODEL_CERTIFIED='yes'
    CHAT_CERTIFIED='yes'
    record_state "$ADMIN_SETUP" "$MODEL_CERTIFIED" "$CHAT_CERTIFIED"
    verify_local_page

    printf '\nOPEN WEBUI CERTIFICATION COMPLETE\n\n'
    show_status
    exit 0
fi

###############################################################################
# Installation
###############################################################################

choose_install_options
printf 'Selected runtime:   %s\n' "$RUNTIME"
printf 'Open WebUI port:    %s\n' "$OPENWEBUI_PORT"
printf 'Network exposure:   loopback only\n'

# Gather all human input before packages are installed or services are changed.
# A rerun uses the existing administrator; a new deployment creates it locally
# after Open WebUI becomes healthy.
if [[ "$ADMIN_SETUP" == 'complete' ]]; then
    collect_existing_admin_credentials
else
    collect_new_admin_credentials
fi

if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    [[ -r "$STATE_FILE" ]] ||
        die "$SERVICE_NAME already exists but is not recorded as project-managed."
    info "Stopping the existing project-managed Open WebUI service"
    systemctl disable --now "$SERVICE_NAME" || true
fi

info "Installing common Open WebUI prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq
verify_ollama

if [[ "$ADMIN_SETUP" != 'complete' ]]; then
    # Record ownership before lengthy runtime installation. This permits a safe
    # rerun if package installation or the later certification step is interrupted.
    record_state 'pending' 'no' 'no'
fi

write_service_environment

if [[ "$RUNTIME" == 'docker' ]]; then
    install_docker_runtime
else
    install_native_runtime
    if command -v docker >/dev/null 2>&1; then
        warn "Docker is installed on this host but is not used by the native deployment."
    fi
fi

chmod 0644 "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
wait_for_openwebui

if [[ "$ADMIN_SETUP" != 'complete' ]]; then
    create_initial_admin
fi

certify_openwebui
ADMIN_SETUP='complete'
MODEL_CERTIFIED='yes'
CHAT_CERTIFIED='yes'
record_state "$ADMIN_SETUP" "$MODEL_CERTIFIED" "$CHAT_CERTIFIED"
verify_local_page

unset ADMIN_PASSWORD AUTH_TOKEN

printf '\nOPEN WEBUI INSTALLATION COMPLETE\n\n'
show_status

SSH_HOST="$(hostname -f 2>/dev/null || hostname)"
cat <<EOF

Open WebUI remains loopback-only. From another computer, create an SSH tunnel:

    ssh -L $OPENWEBUI_PORT:127.0.0.1:$OPENWEBUI_PORT ${SUDO_USER:-user}@$SSH_HOST

Then open:

    http://127.0.0.1:$OPENWEBUI_PORT

For permanent LAN access, use a reverse proxy such as Caddy, Nginx, or Traefik.
The optional Caddy helper is:

    sudo ./05-caddy-setup.bash

Service-management commands:

    sudo ./$PROGRAM_NAME --service start
    sudo ./$PROGRAM_NAME --service stop
    sudo ./$PROGRAM_NAME --service restart
    sudo ./$PROGRAM_NAME --systemd enable
    sudo ./$PROGRAM_NAME --systemd disable
    sudo ./$PROGRAM_NAME --systemd status
    sudo ./$PROGRAM_NAME --check
    sudo ./$PROGRAM_NAME --certify

Disabling controls boot-time startup; it does not stop a running service.
EOF

