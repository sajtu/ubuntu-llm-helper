#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# AI host setup — phase 3: Ollama
#
# Purpose:
#   Install Ollama after phase 1 has configured and verified the GPU, run it as
#   a managed systemd service, and certify real GPU inference with a small model.
#
# Required:
#   - 01-gpu-setup.bash completed successfully
#
# Optional:
#   - 02-nvidia-persistence-m.bash (operational tuning only)
#
# This script intentionally does NOT install or replace GPU drivers, the CUDA
# development toolkit, Docker, Open WebUI, or another LLM platform.
###############################################################################

PROGRAM_NAME="${0##*/}"
FOUNDATION_STATE='/var/lib/ai-host-setup/gpu-foundation.conf'
STATE_DIR='/var/lib/ai-host-setup'
STATE_FILE="$STATE_DIR/ollama.conf"
PROVIDER_DIR="$STATE_DIR/providers.d"
PROVIDER_FILE="$PROVIDER_DIR/ollama.conf"
UNIT_NAME='ollama.service'
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

OLLAMA_HOST='127.0.0.1:11434'
OLLAMA_MODELS='/usr/share/ollama/.ollama/models'
OLLAMA_KEEP_ALIVE='5m'
CERT_MODEL='qwen3:0.6b'

ACTION='install'
FORCE_UPDATE='no'
CERTIFY='yes'
SELECTED_VENDOR=''
TEMP_DIR=''
LIB_BACKUP=''
INSTALL_COMMITTED='no'
CERTIFIED='no'
CERTIFIED_AT=''
VRAM_BYTES='0'
EXPLICIT_ACTIONS=0

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
Usage: sudo ./$PROGRAM_NAME [OPTIONS]

Default action:
  Install and configure Ollama, start it at boot, download a small test model,
  run an inference, and verify that the model used GPU memory.

Options:
  --check                 Check the existing installation; change nothing
  --certify               Repeat GPU certification without reinstalling Ollama
  --update                Download the current Ollama package, then certify
  --skip-certification    Install/configure without downloading a test model
  --model NAME            Certification model (default: $CERT_MODEL)
  --keep-alive DURATION   Default model retention (default: $OLLAMA_KEEP_ALIVE)
  -h, --help              Show this help

Examples:
  sudo ./$PROGRAM_NAME
  sudo ./$PROGRAM_NAME --update
  sudo ./$PROGRAM_NAME --certify
  sudo ./$PROGRAM_NAME --check
  sudo ./$PROGRAM_NAME --keep-alive -1

The API listens only on $OLLAMA_HOST and Ollama cloud features are disabled.
EOF
}

cleanup() {
    local exit_status=$?

    if [[ -n "$LIB_BACKUP" && -d "$LIB_BACKUP" ]]; then
        if [[ "$INSTALL_COMMITTED" == 'yes' ]]; then
            rm -rf -- "$LIB_BACKUP"
        else
            warn "Restoring the previous Ollama runtime libraries."
            rm -rf -- /usr/lib/ollama
            mv -- "$LIB_BACKUP" /usr/lib/ollama
        fi
    fi

    if [[ "$TEMP_DIR" == /tmp/ai-ollama-install.* && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi

    return "$exit_status"
}

trap cleanup EXIT

while (( $# > 0 )); do
    case "$1" in
        --check)
            ACTION='check'
            CERTIFY='no'
            (( EXPLICIT_ACTIONS += 1 ))
            shift
            ;;
        --certify)
            ACTION='certify'
            CERTIFY='yes'
            (( EXPLICIT_ACTIONS += 1 ))
            shift
            ;;
        --update)
            ACTION='install'
            FORCE_UPDATE='yes'
            (( EXPLICIT_ACTIONS += 1 ))
            shift
            ;;
        --skip-certification)
            CERTIFY='no'
            shift
            ;;
        --model)
            (( $# >= 2 )) || die "--model requires an argument."
            CERT_MODEL="$2"
            shift 2
            ;;
        --keep-alive)
            (( $# >= 2 )) || die "--keep-alive requires an argument."
            OLLAMA_KEEP_ALIVE="$2"
            shift 2
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

(( EXPLICIT_ACTIONS <= 1 )) ||
    die "Use only one of --check, --certify, or --update."
[[ "$ACTION" != 'certify' || "$CERTIFY" == 'yes' ]] ||
    die "--certify and --skip-certification cannot be combined."

[[ "$CERT_MODEL" =~ ^[A-Za-z0-9._/@:-]+$ ]] ||
    die "The model name contains unsupported characters: $CERT_MODEL"
[[ "$OLLAMA_KEEP_ALIVE" =~ ^-?[0-9]+(ns|us|ms|s|m|h)?$ ]] ||
    die "Invalid keep-alive value: $OLLAMA_KEEP_ALIVE"

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."
[[ -d /run/systemd/system ]] || die "This host is not running systemd."

###############################################################################
# Verify operating system and phase 1
###############################################################################

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == 'ubuntu' ]] || die "This phase currently supports Ubuntu only."
[[ "${VERSION_ID:-}" == '24.04' ]] ||
    die "This release is not yet supported: ${PRETTY_NAME:-Ubuntu ${VERSION_ID:-unknown}}."
[[ "$(dpkg --print-architecture)" == 'amd64' ]] ||
    die "This phase currently supports Ubuntu amd64 only."

printf 'Operating system: %s\n' "${PRETTY_NAME:-Ubuntu}"
printf 'Kernel:           %s\n' "$(uname -r)"
printf 'Architecture:     %s\n' "$(dpkg --print-architecture)"

[[ -r "$FOUNDATION_STATE" ]] ||
    die "Phase 1 is not recorded. Run 01-gpu-setup.bash first."

state_value() {
    local key="$1"

    awk -F= -v wanted="$key" '
        $1 == wanted {
            print substr($0, index($0, "=") + 1)
            exit
        }
    ' "$FOUNDATION_STATE"
}

[[ "$(state_value PHASE)" == 'gpu-foundation' ]] ||
    die "The phase 1 state file is invalid: $FOUNDATION_STATE"

SELECTED_VENDOR="$(state_value SELECTED_VENDOR)"
case "$SELECTED_VENDOR" in
    nvidia|amd) ;;
    *) die "Unsupported or missing GPU vendor in $FOUNDATION_STATE" ;;
esac

printf 'Phase 1 GPU stack: %s\n' "$SELECTED_VENDOR"
printf 'Phase 2 tuning:    optional (not required by this script)\n'

verify_gpu() {
    info "Verifying the phase 1 GPU foundation"

    if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
        command -v nvidia-smi >/dev/null 2>&1 ||
            die "nvidia-smi is unavailable; phase 1 is not operational."
        command -v modprobe >/dev/null 2>&1 || die "modprobe is unavailable."
        nvidia-smi >/dev/null 2>&1 ||
            die "nvidia-smi cannot communicate with the NVIDIA driver."
        if ! grep -q '^nvidia_uvm ' /proc/modules; then
            [[ "$ACTION" != 'check' ]] ||
                die "nvidia_uvm is not loaded; the NVIDIA compute runtime is incomplete."
            modprobe nvidia_uvm ||
                die "The NVIDIA Unified Memory kernel module could not be loaded."
        fi
        nvidia-smi --query-gpu=index,name,driver_version,memory.total \
            --format=csv,noheader
    else
        [[ -c /dev/kfd ]] || die "/dev/kfd is unavailable; AMD ROCm is not operational."
        command -v rocminfo >/dev/null 2>&1 ||
            die "rocminfo is unavailable; phase 1 is not operational."
        rocminfo >/dev/null 2>&1 ||
            die "rocminfo could not enumerate an AMD compute device."
        printf 'AMD ROCm device enumeration succeeded.\n'
    fi
}

verify_gpu

###############################################################################
# Status and certification
###############################################################################

api_url() {
    printf 'http://%s%s' "$OLLAMA_HOST" "$1"
}

wait_for_api() {
    local attempt

    for attempt in {1..30}; do
        if curl --fail --silent --show-error "$(api_url /api/version)" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    systemctl --no-pager --full status "$UNIT_NAME" || true
    journalctl --no-pager -n 80 -u "$UNIT_NAME" || true
    die "Ollama did not become ready at $OLLAMA_HOST within 30 seconds."
}

show_status() {
    local enabled_state
    local active_state
    local api_version='unavailable'

    command -v ollama >/dev/null 2>&1 || die "Ollama is not installed."
    [[ -f "$UNIT_PATH" ]] || die "$UNIT_PATH is missing."

    enabled_state="$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)"
    active_state="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"

    if [[ "$active_state" == 'active' ]]; then
        api_version="$(curl --fail --silent "$(api_url /api/version)" 2>/dev/null |
            jq -r '.version // "unavailable"' 2>/dev/null || true)"
    fi

    printf 'Ollama command:  %s\n' "$(command -v ollama)"
    printf 'Ollama version:  %s\n' "$(ollama --version 2>&1 | head -n 1)"
    printf 'Service enabled: %s\n' "$enabled_state"
    printf 'Service active:  %s\n' "$active_state"
    printf 'API endpoint:    http://%s\n' "$OLLAMA_HOST"
    printf 'API version:     %s\n' "$api_version"

    [[ "$enabled_state" == 'enabled' ]] || die "Ollama is not enabled at boot."
    [[ "$active_state" == 'active' ]] || die "Ollama is not running."
    [[ "$api_version" != 'unavailable' && -n "$api_version" ]] ||
        die "The Ollama API is unavailable."

    if [[ -r "$STATE_FILE" ]]; then
        printf 'Installer state: %s\n' "$STATE_FILE"
        awk -F= '/^(GPU_CERTIFIED|CERT_MODEL|CERTIFIED_AT)=/ { print "  " $0 }' "$STATE_FILE"
    else
        warn "No phase 3 state file exists yet."
    fi

    printf '\nLoaded models:\n'
    OLLAMA_HOST="$OLLAMA_HOST" ollama ps || true
}

certify_gpu_inference() {
    local request_file
    local response_file
    local ps_file
    local response_text

    info "Downloading certification model $CERT_MODEL"
    OLLAMA_HOST="$OLLAMA_HOST" ollama pull "$CERT_MODEL"

    TEMP_DIR="${TEMP_DIR:-$(mktemp -d /tmp/ai-ollama-install.XXXXXX)}"
    request_file="$TEMP_DIR/certification-request.json"
    response_file="$TEMP_DIR/certification-response.json"
    ps_file="$TEMP_DIR/running-models.json"

    jq -n \
        --arg model "$CERT_MODEL" \
        --arg keep_alive "$OLLAMA_KEEP_ALIVE" \
        '{
            model: $model,
            prompt: "Reply with exactly: GPU certification passed",
            stream: false,
            think: false,
            keep_alive: $keep_alive,
            options: {temperature: 0, num_predict: 16}
        }' > "$request_file"

    info "Running a real Ollama inference"
    curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data-binary "@$request_file" \
        --output "$response_file" \
        "$(api_url /api/generate)"

    jq -e '.done == true and ((.response // .thinking // "") | length > 0)' \
        "$response_file" >/dev/null ||
        die "Ollama did not return a completed inference response."

    response_text="$(jq -r '.response // .thinking // ""' "$response_file")"
    printf 'Model response: %s\n' "$response_text"

    curl --fail --silent --show-error \
        --output "$ps_file" "$(api_url /api/ps)"

    VRAM_BYTES="$(jq -r --arg model "$CERT_MODEL" '
        [
            .models[]?
            | select(.name == $model or .model == $model or
                     (.name | startswith($model + ":")))
            | (.size_vram // 0)
        ]
        | max // 0
    ' "$ps_file")"

    [[ "$VRAM_BYTES" =~ ^[0-9]+$ ]] || die "Ollama returned an invalid VRAM measurement."
    (( VRAM_BYTES > 0 )) || {
        OLLAMA_HOST="$OLLAMA_HOST" ollama ps || true
        die "Inference worked, but Ollama reported no GPU-resident model data."
    }

    printf '\nOllama processor report:\n'
    OLLAMA_HOST="$OLLAMA_HOST" ollama ps

    if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
        printf '\nNVIDIA compute processes:\n'
        nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory \
            --format=csv,noheader || true
    fi

    CERTIFIED='yes'
    CERTIFIED_AT="$(date --iso-8601=seconds)"
    printf '\nGPU certification succeeded; Ollama reports %s VRAM bytes in use.\n' \
        "$VRAM_BYTES"
}

if [[ "$ACTION" == 'check' ]]; then
    info "Checking Ollama"
    command -v curl >/dev/null 2>&1 || die "curl is unavailable."
    command -v jq >/dev/null 2>&1 || die "jq is unavailable."
    show_status
    exit 0
fi

if [[ "$ACTION" == 'certify' ]]; then
    command -v curl >/dev/null 2>&1 || die "curl is unavailable."
    command -v jq >/dev/null 2>&1 || die "jq is unavailable."
    command -v ollama >/dev/null 2>&1 || die "Ollama is not installed."
    [[ -f "$UNIT_PATH" ]] || die "$UNIT_PATH is missing. Run the default install first."
    systemctl is-active --quiet "$UNIT_NAME" || systemctl start "$UNIT_NAME"
    wait_for_api
    certify_gpu_inference
else
    ############################################################################
    # Install Ollama without changing GPU drivers
    ############################################################################

    info "Installing Ollama prerequisites"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq tar zstd

    NEED_PACKAGE='no'
    if ! command -v ollama >/dev/null 2>&1 || [[ ! -d /usr/lib/ollama ]]; then
        NEED_PACKAGE='yes'
    fi
    [[ "$FORCE_UPDATE" == 'yes' ]] && NEED_PACKAGE='yes'

    if [[ "$NEED_PACKAGE" == 'yes' ]]; then
        TEMP_DIR="$(mktemp -d /tmp/ai-ollama-install.XXXXXX)"
        MAIN_ARCHIVE="$TEMP_DIR/ollama-linux-amd64.tar.zst"

        info "Downloading Ollama's official Linux amd64 package"
        curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
            --output "$MAIN_ARCHIVE" \
            'https://ollama.com/download/ollama-linux-amd64.tar.zst'

        tar --zstd -tf "$MAIN_ARCHIVE" > "$TEMP_DIR/main-archive.list"
        grep -Eq '^\.?/?(usr/)?bin/ollama$' "$TEMP_DIR/main-archive.list" ||
            die "The Ollama package does not contain the expected binary."
        if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TEMP_DIR/main-archive.list"; then
            die "The Ollama package contains an unsafe path."
        fi

        systemctl stop "$UNIT_NAME" 2>/dev/null || true

        if [[ -d /usr/lib/ollama ]]; then
            LIB_BACKUP="/usr/lib/ollama.ai-host-backup.$$"
            [[ ! -e "$LIB_BACKUP" ]] || die "Backup path already exists: $LIB_BACKUP"
            mv -- /usr/lib/ollama "$LIB_BACKUP"
        fi

        tar --zstd -xf "$MAIN_ARCHIVE" -C /usr
        [[ -x /usr/bin/ollama ]] || die "Ollama was not installed at /usr/bin/ollama."

        if [[ "$SELECTED_VENDOR" == 'amd' ]]; then
            AMD_ARCHIVE="$TEMP_DIR/ollama-linux-amd64-rocm.tar.zst"
            info "Downloading Ollama's additional AMD ROCm package"
            curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
                --output "$AMD_ARCHIVE" \
                'https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst'
            tar --zstd -tf "$AMD_ARCHIVE" > "$TEMP_DIR/amd-archive.list"
            if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TEMP_DIR/amd-archive.list"; then
                die "The Ollama AMD package contains an unsafe path."
            fi
            tar --zstd -xf "$AMD_ARCHIVE" -C /usr
        fi

    else
        info "Reusing the installed Ollama package"
        printf '%s\n' "Use --update when you want to download the current release."
    fi

    info "Creating the Ollama service account and model directory"
    if ! getent group ollama >/dev/null 2>&1; then
        groupadd --system ollama
    fi
    if ! id ollama >/dev/null 2>&1; then
        useradd --system --gid ollama --create-home \
            --home-dir /usr/share/ollama --shell /usr/sbin/nologin ollama
    fi

    install -d -o ollama -g ollama -m 0750 /usr/share/ollama
    install -d -o ollama -g ollama -m 0750 /usr/share/ollama/.ollama
    install -d -o ollama -g ollama -m 0750 "$OLLAMA_MODELS"
    runuser -u ollama -- test -w /usr/share/ollama/.ollama ||
        die "The Ollama service account cannot write to its state directory."

    for gpu_group in render video; do
        if getent group "$gpu_group" >/dev/null 2>&1; then
            usermod -a -G "$gpu_group" ollama
        fi
    done

    if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
        info "Configuring NVIDIA compute modules for boot"
        cat > /etc/modules-load.d/ai-nvidia-compute.conf <<'EOF'
nvidia
nvidia_uvm
EOF
        chown root:root /etc/modules-load.d/ai-nvidia-compute.conf
        chmod 0644 /etc/modules-load.d/ai-nvidia-compute.conf
    fi

    info "Installing the Ollama systemd service"
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Ollama local model server
Documentation=https://docs.ollama.com/
Wants=network-online.target
After=network-online.target ai-nvidia-persistence.service

[Service]
Type=simple
User=ollama
Group=ollama
ExecStart=/usr/bin/ollama serve
Restart=always
RestartSec=3
Environment="HOME=/usr/share/ollama"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_HOST=$OLLAMA_HOST"
Environment="OLLAMA_MODELS=$OLLAMA_MODELS"
Environment="OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE"
Environment="OLLAMA_NO_CLOUD=1"

[Install]
WantedBy=multi-user.target
EOF

    chown root:root "$UNIT_PATH"
    chmod 0644 "$UNIT_PATH"
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME"
    systemctl restart "$UNIT_NAME"
    wait_for_api
    INSTALL_COMMITTED='yes'

    printf 'Installed version: %s\n' "$(ollama --version 2>&1 | head -n 1)"
    printf 'API endpoint:      http://%s\n' "$OLLAMA_HOST"
    printf 'Model directory:   %s\n' "$OLLAMA_MODELS"
    printf 'Default keep-alive:%s\n' " $OLLAMA_KEEP_ALIVE"
    printf 'Cloud features:    disabled\n'

    if [[ "$CERTIFY" == 'yes' ]]; then
        certify_gpu_inference
    fi
fi

###############################################################################
# Record phase 3 state
###############################################################################

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

{
    printf 'PHASE=%q\n' 'ollama'
    printf 'SELECTED_VENDOR=%q\n' "$SELECTED_VENDOR"
    printf 'OLLAMA_VERSION=%q\n' "$(ollama --version 2>&1 | head -n 1)"
    printf 'OLLAMA_HOST=%q\n' "$OLLAMA_HOST"
    printf 'OLLAMA_MODELS=%q\n' "$OLLAMA_MODELS"
    printf 'OLLAMA_KEEP_ALIVE=%q\n' "$OLLAMA_KEEP_ALIVE"
    printf 'OLLAMA_CLOUD_ENABLED=%q\n' 'no'
    printf 'GPU_CERTIFIED=%q\n' "$CERTIFIED"
    printf 'CERT_MODEL=%q\n' "$CERT_MODEL"
    printf 'CERT_VRAM_BYTES=%q\n' "$VRAM_BYTES"
    printf 'CERTIFIED_AT=%q\n' "$CERTIFIED_AT"
    printf 'CONFIGURED_AT=%q\n' "$(date --iso-8601=seconds)"
} > "$STATE_FILE"

chmod 0644 "$STATE_FILE"

mkdir -p "$PROVIDER_DIR"
chmod 0755 "$PROVIDER_DIR"

{
    printf 'SCHEMA_VERSION=%q\n' '1'
    printf 'PROVIDER_ID=%q\n' 'ollama'
    printf 'PROVIDER_NAME=%q\n' 'Ollama'
    printf 'PROTOCOL=%q\n' 'ollama'
    printf 'BASE_URL=%q\n' "http://$OLLAMA_HOST"
    printf 'MODEL_LIST_PATH=%q\n' '/api/tags'
    printf 'SERVICE_NAME=%q\n' "$UNIT_NAME"
    printf 'MANAGED_BY=%q\n' "$PROGRAM_NAME"
    printf 'REGISTERED_AT=%q\n' "$(date --iso-8601=seconds)"
} > "$PROVIDER_FILE"

chmod 0644 "$PROVIDER_FILE"

printf '\nOLLAMA PHASE COMPLETE\n\n'
printf 'Service:           enabled and running\n'
printf 'API:               http://%s\n' "$OLLAMA_HOST"
printf 'GPU certified:     %s\n' "$CERTIFIED"
printf 'State file:        %s\n' "$STATE_FILE"
printf 'Provider record:   %s\n' "$PROVIDER_FILE"

cat <<EOF

Useful commands:

    ollama list
    ollama ps
    ollama run $CERT_MODEL
    sudo systemctl status ollama
    sudo journalctl -u ollama -f

The API is loopback-only. A later Open WebUI installation on this host can use
http://127.0.0.1:11434 without exposing Ollama's unauthenticated API directly.

No CUDA development toolkit, Docker component, or GPU driver was installed or
changed by this phase.
EOF

