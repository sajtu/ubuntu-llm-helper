#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# AI host setup — phase 1: GPU foundation
#
# Purpose:
#   Install and verify the host GPU driver/runtime prerequisites needed before
#   installing Ollama or another local-AI platform.
#
# This script intentionally does NOT install:
#   - Ollama or another model server
#   - models
#   - the NVIDIA CUDA Toolkit/compiler
#   - NVIDIA Container Toolkit or Docker
#
# Supported operating system:
#   - Ubuntu Server/Desktop 24.04 LTS (amd64)
#
# Vendor behavior:
#   - auto:   prefer NVIDIA if NVIDIA and AMD adapters are both present
#   - nvidia: install Ubuntu's recommended compute/server NVIDIA driver
#   - amd:    install AMD's pinned Radeon/ROCm stack after compatibility consent
#
# NVIDIA compute hosts enable persistence mode by default through a dedicated
# systemd oneshot service. Use --persistence disable or unchanged to override.
#
# AMD packages are pinned because AMD's repository URLs and compatibility
# matrix are release-specific. Override the values only after checking AMD's
# current documentation:
#
#   AMDGPU_INSTALL_VERSION=7.2.1
#   AMDGPU_INSTALL_BUILD=70201
###############################################################################

PROGRAM_NAME="${0##*/}"
STATE_DIR='/var/lib/ai-host-setup'
STATE_FILE="$STATE_DIR/gpu-foundation.conf"

REQUESTED_VENDOR='auto'
CHECK_ONLY='no'
PERSISTENCE_REQUEST='auto'
PERSISTENCE_ACTION=''
STORED_PERSISTENCE_POLICY=''

NVIDIA_PERSISTENCE_UNIT='ai-nvidia-persistence.service'
NVIDIA_PERSISTENCE_UNIT_PATH="/etc/systemd/system/$NVIDIA_PERSISTENCE_UNIT"

AMDGPU_INSTALL_VERSION="${AMDGPU_INSTALL_VERSION:-7.2.1}"
AMDGPU_INSTALL_BUILD="${AMDGPU_INSTALL_BUILD:-70201}"
AI_AMD_ROCM_CONFIRMED="${AI_AMD_ROCM_CONFIRMED:-0}"
AI_GPU_USER="${AI_GPU_USER:-${SUDO_USER:-}}"

TEMP_DIR=''
REBOOT_REQUIRED='no'
SELECTED_VENDOR=''
NVIDIA_PRESENT='no'
AMD_PRESENT='no'

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
Usage: sudo $PROGRAM_NAME [OPTIONS]

Options:
  --vendor auto|nvidia|amd   GPU stack to configure (default: auto)
  --persistence MODE         NVIDIA persistence: enable, disable, or unchanged
                             (default: saved policy; fresh NVIDIA hosts enable)
  --check                    Inventory and verify only; change nothing
  -h, --help                 Show this help

Examples:
  sudo ./$PROGRAM_NAME --check
  sudo ./$PROGRAM_NAME
  sudo ./$PROGRAM_NAME --vendor nvidia
  sudo ./$PROGRAM_NAME --vendor nvidia --persistence disable
  sudo ./$PROGRAM_NAME --vendor nvidia --persistence enable
  sudo ./$PROGRAM_NAME --vendor amd

For unattended AMD installation, compatibility must be acknowledged explicitly:
  sudo AI_AMD_ROCM_CONFIRMED=1 ./$PROGRAM_NAME --vendor amd
EOF
}

cleanup() {
    if [[ "$TEMP_DIR" == /tmp/ai-amdgpu-install.* && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

while (( $# > 0 )); do
    case "$1" in
        --vendor)
            (( $# >= 2 )) || die "--vendor requires an argument."
            REQUESTED_VENDOR="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY='yes'
            shift
            ;;
        --persistence)
            (( $# >= 2 )) || die "--persistence requires an argument."
            PERSISTENCE_REQUEST="$2"
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

case "$REQUESTED_VENDOR" in
    auto|nvidia|amd) ;;
    *) die "--vendor must be auto, nvidia, or amd." ;;
esac

case "$PERSISTENCE_REQUEST" in
    auto|enable|disable|unchanged) ;;
    *) die "--persistence must be enable, disable, or unchanged." ;;
esac

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."

###############################################################################
# Operating-system checks
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

###############################################################################
# Hardware inventory (works even before pciutils is installed)
###############################################################################

pci_vendor_present() {
    local wanted_vendor="$1"
    local vendor_file

    for vendor_file in /sys/bus/pci/devices/*/vendor; do
        [[ -r "$vendor_file" ]] || continue
        [[ "$(<"$vendor_file")" == "$wanted_vendor" ]] && return 0
    done

    return 1
}

pci_vendor_present '0x10de' && NVIDIA_PRESENT='yes'
pci_vendor_present '0x1002' && AMD_PRESENT='yes'

info "Detected graphics hardware"

if command -v lspci >/dev/null 2>&1; then
    lspci -nnk | awk '
        BEGIN { IGNORECASE=1 }
        /VGA compatible controller|3D controller|Display controller/ {
            print
            show=1
            next
        }
        show && /^[[:space:]]+(Subsystem|Kernel driver in use|Kernel modules):/ {
            print
            next
        }
        { show=0 }
    '
else
    printf 'pciutils is not installed; detailed adapter names are unavailable.\n'
fi

printf '\nNVIDIA PCI device present: %s\n' "$NVIDIA_PRESENT"
printf 'AMD PCI device present:    %s\n' "$AMD_PRESENT"

if [[ "$NVIDIA_PRESENT" == 'no' && "$AMD_PRESENT" == 'no' ]]; then
    die "No NVIDIA or AMD PCI GPU was detected."
fi

case "$REQUESTED_VENDOR" in
    auto)
        if [[ "$NVIDIA_PRESENT" == 'yes' ]]; then
            SELECTED_VENDOR='nvidia'
        else
            SELECTED_VENDOR='amd'
        fi
        ;;
    nvidia)
        [[ "$NVIDIA_PRESENT" == 'yes' ]] || die "No NVIDIA PCI GPU was detected."
        SELECTED_VENDOR='nvidia'
        ;;
    amd)
        [[ "$AMD_PRESENT" == 'yes' ]] || die "No AMD PCI GPU was detected."
        SELECTED_VENDOR='amd'
        ;;
esac

printf 'Selected compute stack:    %s\n' "$SELECTED_VENDOR"

if [[ "$PERSISTENCE_REQUEST" == 'auto' ]]; then
    if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
        if [[ -r "$STATE_FILE" ]]; then
            STORED_PERSISTENCE_POLICY="$(
                awk -F= '$1 == "NVIDIA_PERSISTENCE_POLICY" {
                    print substr($0, index($0, "=") + 1)
                    exit
                }' "$STATE_FILE"
            )"
        fi

        # Once our unit exists, systemd is the source of truth. This preserves
        # a user's direct `systemctl enable` or `systemctl disable` choice on
        # later script runs instead of overwriting it from an older state file.
        if [[ -e "$NVIDIA_PERSISTENCE_UNIT_PATH" ]]; then
            if systemctl is-enabled --quiet "$NVIDIA_PERSISTENCE_UNIT"; then
                STORED_PERSISTENCE_POLICY='enable'
            else
                STORED_PERSISTENCE_POLICY='disable'
            fi
        fi

        case "$STORED_PERSISTENCE_POLICY" in
            enable|disable|unchanged)
                PERSISTENCE_ACTION="$STORED_PERSISTENCE_POLICY"
                ;;
            *)
                PERSISTENCE_ACTION='enable'
                ;;
        esac
    else
        PERSISTENCE_ACTION='unchanged'
    fi
else
    PERSISTENCE_ACTION="$PERSISTENCE_REQUEST"
fi

if [[ "$SELECTED_VENDOR" != 'nvidia' &&
      "$PERSISTENCE_ACTION" != 'unchanged' ]]; then
    die "NVIDIA persistence mode can only be managed with --vendor nvidia."
fi

printf 'NVIDIA persistence policy: %s\n' "$PERSISTENCE_ACTION"

if [[ "$NVIDIA_PRESENT" == 'yes' && "$AMD_PRESENT" == 'yes' &&
      "$REQUESTED_VENDOR" == 'auto' ]]; then
    printf 'Hybrid system policy:     NVIDIA preferred; AMD left as display/inbox GPU.\n'
fi

###############################################################################
# Read-only status functions
###############################################################################

secure_boot_status() {
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null || printf 'unknown\n'
    else
        printf 'unknown (mokutil not installed)\n'
    fi
}

show_nvidia_persistence_status() {
    local service_enabled='not-installed'
    local persistence_output=''

    if [[ -e "$NVIDIA_PERSISTENCE_UNIT_PATH" ]]; then
        service_enabled="$(systemctl is-enabled "$NVIDIA_PERSISTENCE_UNIT" 2>/dev/null || true)"
        [[ -n "$service_enabled" ]] || service_enabled='unknown'
    fi

    printf 'Persistence boot service: %s\n' "$service_enabled"

    if ! command -v nvidia-smi >/dev/null 2>&1 ||
       ! nvidia-smi >/dev/null 2>&1; then
        printf 'Persistence live state:   unavailable\n'
        return 0
    fi

    persistence_output="$(
        nvidia-smi --query-gpu=index,name,persistence_mode --format=csv,noheader
    )"

    printf 'Persistence live state:\n%s\n' "$persistence_output"

    case "$PERSISTENCE_ACTION" in
        enable)
            if [[ "$service_enabled" != 'enabled' ]]; then
                warn "Persistence was requested, but its boot service is not enabled."
                return 1
            fi

            if grep -qE ',[[:space:]]*(Disabled|N/A)[[:space:]]*$' \
                <<< "$persistence_output"; then
                warn "Persistence is not active on every NVIDIA GPU."
                return 1
            fi
            ;;

        disable)
            if [[ "$service_enabled" == 'enabled' ]]; then
                warn "Persistence was requested off, but its boot service is enabled."
                return 1
            fi

            if grep -qE ',[[:space:]]*Enabled[[:space:]]*$' \
                <<< "$persistence_output"; then
                warn "Persistence is still active on at least one NVIDIA GPU."
                return 1
            fi
            ;;
    esac

    return 0
}

show_nvidia_status() {
    local driver_version=''
    local gpu_summary=''

    info "NVIDIA status"

    printf 'Secure Boot: %s\n' "$(secure_boot_status)"

    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            gpu_summary="$(
                nvidia-smi --query-gpu=name,driver_version,memory.total \
                    --format=csv,noheader
            )"
            driver_version="$(
                nvidia-smi --query-gpu=driver_version --format=csv,noheader |
                    head -1 | tr -d '[:space:]'
            )"

            [[ -n "$gpu_summary" ]] || {
                warn "nvidia-smi did not report an NVIDIA GPU."
                return 1
            }

            printf '%s\n' "$gpu_summary"

            if [[ "$(printf '%s\n%s\n' '531' "$driver_version" | sort -V | head -1)" != '531' ]]; then
                warn "The NVIDIA driver is older than the required 531 baseline: $driver_version"
                return 1
            fi

            show_nvidia_persistence_status || return 1

            return 0
        fi

        warn "nvidia-smi is installed but cannot communicate with the GPU."
    else
        printf 'nvidia-smi: not installed\n'
    fi

    if [[ -r /proc/driver/nvidia/version ]]; then
        sed -n '1p' /proc/driver/nvidia/version
    fi

    if command -v lsmod >/dev/null 2>&1; then
        lsmod | awk '$1 ~ /^(nvidia|nouveau)/ { print }' || true
    fi

    return 1
}

show_amd_status() {
    local rocminfo_command=''
    local rocminfo_output=''

    info "AMD status"

    if command -v lsmod >/dev/null 2>&1; then
        if lsmod | grep -q '^amdgpu'; then
            printf 'amdgpu kernel module: loaded\n'
        else
            printf 'amdgpu kernel module: not loaded\n'
        fi
    fi

    if command -v rocminfo >/dev/null 2>&1; then
        rocminfo_command="$(command -v rocminfo)"
    elif [[ -x /opt/rocm/bin/rocminfo ]]; then
        rocminfo_command='/opt/rocm/bin/rocminfo'
    fi

    if [[ -n "$rocminfo_command" ]]; then
        rocminfo_output="$("$rocminfo_command" 2>/dev/null || true)"

        if grep -qE 'Device Type:[[:space:]]+GPU' <<< "$rocminfo_output"; then
            printf '%s\n' "$rocminfo_output" |
                awk '/^[[:space:]]*Name:[[:space:]]/ || /^[[:space:]]*Marketing Name:[[:space:]]/ {
                    print
                }' | head -20
            return 0
        fi

        warn "rocminfo is installed but did not initialize successfully."
    else
        printf 'rocminfo: not installed\n'
    fi

    return 1
}

if [[ "$CHECK_ONLY" == 'yes' ]]; then
    if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
        if ! show_nvidia_status; then
            printf '\nCHECK FAILED: the NVIDIA compute stack is not ready.\n' >&2
            exit 1
        fi
    else
        if ! show_amd_status; then
            printf '\nCHECK FAILED: the AMD ROCm compute stack is not ready.\n' >&2
            exit 1
        fi
    fi

    printf '\nCHECK COMPLETE: no changes were made.\n'
    exit 0
fi

if [[ -e /var/run/reboot-required ]]; then
    warn "Ubuntu reports that a reboot is already required from earlier updates."
    die "Reboot first, reconnect through SSH, and then rerun this phase."
fi

###############################################################################
# Common packages
###############################################################################

info "Installing common GPU foundation packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    dkms \
    gnupg \
    kmod \
    "linux-headers-$(uname -r)" \
    mokutil \
    pciutils

###############################################################################
# NVIDIA path
###############################################################################

install_nvidia() {
    local installed_driver_packages=''
    local driver_package=''
    local driver_branch=''
    local loaded_version=''
    local module_branch=''
    local module_version=''
    local utils_package=''

    info "Installing Ubuntu's recommended NVIDIA compute driver"

    if command -v nvidia-smi >/dev/null 2>&1 &&
       nvidia-smi >/dev/null 2>&1; then
        loaded_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader |
            head -1 | tr -d '[:space:]')"

        if [[ "$(printf '%s\n%s\n' '531' "$loaded_version" | sort -V | head -1)" == '531' ]]; then
            printf 'A usable NVIDIA driver is already loaded: %s\n' "$loaded_version"
            return 0
        fi

        warn "The loaded NVIDIA driver is older than the required 531 baseline."
    fi

    apt-get install -y ubuntu-drivers-common

    printf 'Available compute-driver packages:\n'
    ubuntu-drivers list --gpgpu || true

    installed_driver_packages="$(
        { dpkg-query -W -f='${Package} ${db:Status-Status}\n' \
            'nvidia-driver-*' \
            'nvidia-headless-*' 2>/dev/null || true; } |
            awk '$2 == "installed" { print $1 }' |
            sort -V
    )"

    # If a driver is already installed, do not ask ubuntu-drivers to select a
    # branch again merely because nvidia-smi is missing. The management binary
    # is packaged separately on Ubuntu's headless driver path.
    if [[ -z "$installed_driver_packages" ]]; then
        # Canonical recommends ubuntu-drivers for automatic selection and
        # signed Secure Boot-compatible packages from Ubuntu's archive.
        ubuntu-drivers install --gpgpu

        installed_driver_packages="$(
            { dpkg-query -W -f='${Package} ${db:Status-Status}\n' \
                'nvidia-driver-*' \
                'nvidia-headless-*' 2>/dev/null || true; } |
                awk '$2 == "installed" { print $1 }' |
                sort -V
        )"
    else
        printf 'An NVIDIA driver package is already installed; retaining its branch.\n'
    fi

    # Prefer the package matching the module installed for the running kernel.
    module_version="$(modinfo -F version nvidia 2>/dev/null | head -1 || true)"
    module_branch="${module_version%%.*}"

    if [[ "$module_branch" =~ ^[0-9]+$ ]]; then
        driver_package="$(
            grep -E -- "-${module_branch}(-server)?(-open)?$" \
                <<< "$installed_driver_packages" |
                tail -1 || true
        )"
    fi

    if [[ -z "$driver_package" ]]; then
        driver_package="$(tail -1 <<< "$installed_driver_packages")"
    fi

    [[ -n "$driver_package" ]] ||
        die "ubuntu-drivers completed but no NVIDIA driver or headless metapackage is installed."

    if [[ "$driver_package" =~ -([0-9]+)-server(-open)?$ ]]; then
        driver_branch="${BASH_REMATCH[1]}"
        utils_package="nvidia-utils-${driver_branch}-server"
    elif [[ "$driver_package" =~ -([0-9]+)(-open)?$ ]]; then
        driver_branch="${BASH_REMATCH[1]}"
        utils_package="nvidia-utils-${driver_branch}"
    else
        die "Could not determine the NVIDIA branch from $driver_package."
    fi

    # nvidia-compute-utils contains persistence and MPS programs. nvidia-smi
    # itself is supplied by the matching nvidia-utils package.
    apt-get install -y "$utils_package"

    command -v nvidia-smi >/dev/null 2>&1 ||
        die "$utils_package is installed but nvidia-smi is unavailable."

    printf 'Installed driver package: %s\n' "$driver_package"
    printf 'Installed utility package: %s\n' "$utils_package"
    printf 'Installed driver branch:  %s\n' "$driver_branch"

    if nvidia-smi >/dev/null 2>&1; then
        printf 'NVIDIA driver verification succeeded without a reboot.\n'
        REBOOT_REQUIRED='no'
    else
        REBOOT_REQUIRED='yes'
    fi
}

install_nvidia_persistence_unit() {
    info "Installing NVIDIA persistence-mode boot service"

    cat > "$NVIDIA_PERSISTENCE_UNIT_PATH" <<'EOF'
[Unit]
Description=Enable NVIDIA GPU persistence mode for AI compute
After=systemd-modules-load.service
Before=ollama.service
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/modprobe nvidia
ExecStart=/usr/bin/nvidia-smi --persistence-mode=1
ExecStop=-/usr/bin/nvidia-smi --persistence-mode=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    chown root:root "$NVIDIA_PERSISTENCE_UNIT_PATH"
    chmod 0644 "$NVIDIA_PERSISTENCE_UNIT_PATH"
    systemctl daemon-reload
}

configure_nvidia_persistence() {
    local persistence_output=''

    case "$PERSISTENCE_ACTION" in
        unchanged)
            printf 'NVIDIA persistence configuration was left unchanged.\n'
            return 0
            ;;

        enable)
            install_nvidia_persistence_unit

            if [[ "$REBOOT_REQUIRED" == 'yes' ]] ||
               ! nvidia-smi >/dev/null 2>&1; then
                systemctl enable "$NVIDIA_PERSISTENCE_UNIT"
                printf 'Persistence mode will be enabled during the next boot.\n'
                return 0
            fi

            systemctl enable --now "$NVIDIA_PERSISTENCE_UNIT"
            ;;

        disable)
            if [[ -e "$NVIDIA_PERSISTENCE_UNIT_PATH" ]]; then
                systemctl disable --now "$NVIDIA_PERSISTENCE_UNIT" || true
            fi

            # If the unit was not active, systemd has no ExecStop action to
            # invoke. Set the live state explicitly so disable means both
            # "off now" and "off after reboot."
            if nvidia-smi >/dev/null 2>&1; then
                nvidia-smi --persistence-mode=0
            elif [[ "$REBOOT_REQUIRED" != 'yes' ]]; then
                die "Could not disable persistence mode because nvidia-smi is unavailable."
            fi
            ;;
    esac

    if nvidia-smi >/dev/null 2>&1; then
        persistence_output="$(
            nvidia-smi --query-gpu=index,name,persistence_mode --format=csv,noheader
        )"
        printf 'Persistence live state:\n%s\n' "$persistence_output"

        if [[ "$PERSISTENCE_ACTION" == 'enable' ]] &&
           grep -qE ',[[:space:]]*(Disabled|N/A)[[:space:]]*$' <<< "$persistence_output"; then
            die "Persistence mode was not enabled on every NVIDIA GPU."
        fi

        if [[ "$PERSISTENCE_ACTION" == 'disable' ]] &&
           grep -qE ',[[:space:]]*Enabled[[:space:]]*$' <<< "$persistence_output"; then
            die "Persistence mode was not disabled on every NVIDIA GPU."
        fi
    fi
}

###############################################################################
# AMD path
###############################################################################

confirm_amd_compatibility() {
    info "AMD ROCm compatibility gate"

    cat <<'EOF'
ROCm does not support every Radeon GPU. An AMD adapter being visible through
lspci or the amdgpu kernel module does not prove ROCm compatibility.

Confirm the exact GPU against AMD's current Radeon/Ryzen ROCm compatibility
matrix before continuing. Older Ryzen/Vega integrated GPUs, including the
Ryzen 9 5900HS iGPU, are not supported ROCm compute targets.
EOF

    if [[ "$AI_AMD_ROCM_CONFIRMED" == '1' ]]; then
        printf 'AMD compatibility acknowledged through AI_AMD_ROCM_CONFIRMED=1.\n'
        return 0
    fi

    [[ -t 0 ]] ||
        die "Set AI_AMD_ROCM_CONFIRMED=1 after verifying AMD compatibility."

    read -r -p "Is this exact AMD GPU supported by the current ROCm release? [y/N]: " response
    [[ "$response" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || die "AMD installation cancelled."
}

install_amd() {
    local installer_deb
    local installer_url

    if show_amd_status; then
        printf 'A usable ROCm GPU agent is already available.\n'
        return 0
    fi

    confirm_amd_compatibility

    info "Installing AMD Radeon and ROCm foundation"

    apt-get install -y python3-setuptools python3-wheel wget

    TEMP_DIR="$(mktemp -d /tmp/ai-amdgpu-install.XXXXXX)"
    installer_deb="$TEMP_DIR/amdgpu-install.deb"
    installer_url="https://repo.radeon.com/amdgpu-install/${AMDGPU_INSTALL_VERSION}/ubuntu/noble/amdgpu-install_${AMDGPU_INSTALL_VERSION}.${AMDGPU_INSTALL_BUILD}-1_all.deb"

    printf 'AMD installer version: %s\n' "$AMDGPU_INSTALL_VERSION"
    printf 'AMD installer URL:     %s\n' "$installer_url"

    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "$installer_deb" "$installer_url"

    dpkg-deb --info "$installer_deb" >/dev/null ||
        die "The downloaded AMD installer is not a valid Debian package."

    apt-get install -y "$installer_deb"

    command -v amdgpu-install >/dev/null 2>&1 ||
        die "amdgpu-install is unavailable after installing AMD's package."

    amdgpu-install -y --usecase=graphics,rocm

    if [[ -n "$AI_GPU_USER" && "$AI_GPU_USER" != 'root' ]]; then
        if id "$AI_GPU_USER" >/dev/null 2>&1; then
            usermod -a -G render,video "$AI_GPU_USER"
            printf 'Added %s to the render and video groups.\n' "$AI_GPU_USER"
        else
            warn "AI_GPU_USER does not exist: $AI_GPU_USER"
        fi
    else
        warn "No non-root AI_GPU_USER was selected; configure service-user GPU access later."
    fi

    REBOOT_REQUIRED='yes'
}

if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
    install_nvidia
    configure_nvidia_persistence
else
    install_amd
fi

###############################################################################
# State and next action
###############################################################################

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

{
    printf 'PHASE=%q\n' 'gpu-foundation'
    printf 'OPERATING_SYSTEM=%q\n' "${PRETTY_NAME:-Ubuntu}"
    printf 'KERNEL=%q\n' "$(uname -r)"
    printf 'SELECTED_VENDOR=%q\n' "$SELECTED_VENDOR"
    printf 'NVIDIA_PRESENT=%q\n' "$NVIDIA_PRESENT"
    printf 'AMD_PRESENT=%q\n' "$AMD_PRESENT"
    printf 'REBOOT_REQUIRED=%q\n' "$REBOOT_REQUIRED"
    printf 'NVIDIA_PERSISTENCE_POLICY=%q\n' "$PERSISTENCE_ACTION"
    printf 'CONFIGURED_AT=%q\n' "$(date --iso-8601=seconds)"
} > "$STATE_FILE"

chmod 0644 "$STATE_FILE"

printf '\nINSTALLATION PHASE COMPLETE\n\n'
printf 'Selected compute stack: %s\n' "$SELECTED_VENDOR"
printf 'State file:             %s\n' "$STATE_FILE"

if [[ "$SELECTED_VENDOR" == 'nvidia' ]]; then
    printf 'Persistence policy:     %s\n' "$PERSISTENCE_ACTION"
    printf 'Persistence service:    %s\n' "$NVIDIA_PERSISTENCE_UNIT"
fi

if [[ "$REBOOT_REQUIRED" == 'yes' ]]; then
    cat <<EOF

A reboot is required before driver verification:

    sudo reboot

After reconnecting through SSH, run:

    sudo ./$PROGRAM_NAME --vendor $SELECTED_VENDOR --check

No LLM platform, model, CUDA development toolkit, Docker component, or Ollama
package was installed by this phase.
EOF
else
    cat <<EOF

GPU driver verification succeeded; no reboot is required by this phase.

To repeat the read-only verification later:

    sudo ./$PROGRAM_NAME --vendor $SELECTED_VENDOR --check

No LLM platform, model, CUDA development toolkit, Docker component, or Ollama
package was installed by this phase.
EOF
fi

