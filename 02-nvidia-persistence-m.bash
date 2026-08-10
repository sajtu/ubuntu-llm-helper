#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# NVIDIA persistence-mode control
#
# This utility installs and controls a small systemd oneshot service that
# enables NVIDIA persistence mode at boot. It does not install or update any
# packages, drivers, CUDA components, model servers, or models.
###############################################################################

PROGRAM_NAME="${0##*/}"
UNIT_NAME='ai-nvidia-persistence.service'
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
ACTION="${1:-status}"

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME enable|disable|status

Actions:
  enable    Turn persistence mode on now and automatically at boot
  disable   Turn persistence mode off now and prevent it at boot
  status    Show the systemd boot policy and live state; change nothing

Aliases:
  on        Same as enable
  off       Same as disable
  --check   Same as status

Examples:
  sudo ./$PROGRAM_NAME enable
  sudo ./$PROGRAM_NAME disable
  ./$PROGRAM_NAME status
EOF
}

case "$ACTION" in
    enable|on)
        ACTION='enable'
        ;;
    disable|off)
        ACTION='disable'
        ;;
    status|--check)
        ACTION='status'
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "Unknown action: $ACTION"
        ;;
esac

(( $# <= 1 )) || die "Only one action may be specified."

[[ "$(uname -s)" == 'Linux' ]] || die "This utility requires Linux."
[[ -d /run/systemd/system ]] || die "This host is not running systemd."

command -v systemctl >/dev/null 2>&1 || die "systemctl is unavailable."
command -v nvidia-smi >/dev/null 2>&1 ||
    die "nvidia-smi is unavailable; complete the NVIDIA driver setup first."

NVIDIA_SMI="$(command -v nvidia-smi)"
MODPROBE="$(command -v modprobe || true)"

[[ -n "$MODPROBE" ]] || die "modprobe is unavailable."

if ! "$NVIDIA_SMI" >/dev/null 2>&1; then
    die "nvidia-smi cannot communicate with the NVIDIA driver."
fi

service_enabled_state() {
    if [[ ! -e "$UNIT_PATH" ]]; then
        printf 'not-installed\n'
        return 0
    fi

    systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true
}

service_active_state() {
    if [[ ! -e "$UNIT_PATH" ]]; then
        printf 'not-installed\n'
        return 0
    fi

    systemctl is-active "$UNIT_NAME" 2>/dev/null || true
}

live_state() {
    "$NVIDIA_SMI" \
        --query-gpu=index,name,persistence_mode \
        --format=csv,noheader
}

show_status() {
    local enabled_state
    local active_state
    local gpu_state

    enabled_state="$(service_enabled_state)"
    active_state="$(service_active_state)"
    gpu_state="$(live_state)"

    printf 'Persistence service: %s\n' "$UNIT_NAME"
    printf 'Boot policy:        %s\n' "$enabled_state"
    printf 'Service state:      %s\n' "$active_state"
    printf 'Live GPU state:\n%s\n' "$gpu_state"

    if [[ "$enabled_state" == 'enabled' ]]; then
        if [[ "$active_state" != 'active' ]]; then
            warn "The persistence service is enabled but is not active."
            return 1
        fi

        if grep -qE ',[[:space:]]*(Disabled|N/A)[[:space:]]*$' <<< "$gpu_state"; then
            warn "The service is enabled but persistence is not active on every GPU."
            return 1
        fi
    elif grep -qE ',[[:space:]]*Enabled[[:space:]]*$' <<< "$gpu_state"; then
        warn "Persistence is currently on but is not enabled through the boot service."
        return 1
    fi

    return 0
}

install_unit() {
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Enable NVIDIA GPU persistence mode for AI compute
After=systemd-modules-load.service
Before=ollama.service
ConditionPathExists=$NVIDIA_SMI

[Service]
Type=oneshot
ExecStartPre=$MODPROBE nvidia
ExecStart=$NVIDIA_SMI --persistence-mode=1
ExecStop=-$NVIDIA_SMI --persistence-mode=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    chown root:root "$UNIT_PATH"
    chmod 0644 "$UNIT_PATH"
    systemctl daemon-reload
}

case "$ACTION" in
    status)
        show_status
        exit $?
        ;;

    enable)
        [[ "$EUID" -eq 0 ]] || die "Run the enable action with sudo or as root."

        install_unit
        systemctl enable --now "$UNIT_NAME"

        show_status || die "Persistence mode did not enable successfully."
        printf '\nNVIDIA persistence mode is enabled now and at boot.\n'
        ;;

    disable)
        [[ "$EUID" -eq 0 ]] || die "Run the disable action with sudo or as root."

        if [[ -e "$UNIT_PATH" ]]; then
            systemctl disable --now "$UNIT_NAME" || true
        fi

        # Apply the requested live state even if the unit was already inactive
        # and therefore had no ExecStop transition for systemd to invoke.
        "$NVIDIA_SMI" --persistence-mode=0

        show_status || die "Persistence mode did not disable successfully."
        printf '\nNVIDIA persistence mode is disabled now and at boot.\n'
        ;;
esac
