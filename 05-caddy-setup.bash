#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# AI host setup — phase 5: interactive Caddy LAN proxy for Open WebUI
#
# Requires a completed phase 04 installation. Open WebUI remains on loopback;
# Caddy exposes it on explicitly selected active IPv4 interfaces.
###############################################################################

PROGRAM_NAME="${0##*/}"
AI_STATE_DIR='/var/lib/ai-host-setup'
OPENWEBUI_STATE="$AI_STATE_DIR/open-webui.conf"
STATE_FILE="$AI_STATE_DIR/caddy-open-webui.conf"

CADDYFILE='/etc/caddy/Caddyfile'
CADDY_CONFIG_DIR='/etc/caddy/conf.d'
CADDY_SNIPPET="$CADDY_CONFIG_DIR/open-webui.caddy"
CADDY_MARKER='# Managed by ubuntu-llm-helper: Open WebUI'
CADDY_IMPORT_MARKER='# ubuntu-llm-helper managed Caddy imports'
CADDY_IMPORT_LINE="import $CADDY_CONFIG_DIR/*.caddy"

CERT_DIR='/etc/caddy/certs/open-webui'
LOCAL_CA_CERT="$CERT_DIR/local-ca.crt"
LOCAL_CA_KEY="$CERT_DIR/local-ca.key"
LOCAL_CA_SERIAL="$CERT_DIR/local-ca.srl"
FALLBACK_CERT="$CERT_DIR/fallback-fullchain.pem"
FALLBACK_LEAF_CERT="$CERT_DIR/fallback-leaf.crt"
FALLBACK_KEY="$CERT_DIR/fallback.key"
CUSTOM_CERT="$CERT_DIR/custom-fullchain.pem"
CUSTOM_KEY="$CERT_DIR/custom.key"

MODE=''
OPENWEBUI_PORT=''
OPENWEBUI_URL=''
BIND_MODE='selected'
BIND_VALUE=''
HTTPS_PORT='443'
HTTP_ENABLED='no'
HTTP_PORT='80'
CERT_MODE='self-signed'
ACTIVE_CERT=''
ACTIVE_KEY=''
CUSTOM_CERT_SOURCE=''
CUSTOM_KEY_SOURCE=''
CONFIG_CHANGED='no'
CERT_CHANGED='no'
CHOSEN_PORT=''

declare -a IF_NAMES=()
declare -a IF_IPS=()
declare -a SELECTED_INDEXES=()
declare -a SELECTED_IPS=()
declare -a SELECTED_INTERFACES=()
declare -a SELECTED_HOSTNAMES=()
declare -a DISCOVERED_HOSTNAMES=()
declare -a FORCED_PORTS=()

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

yes_answer() {
    [[ "${1:-}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

usage() {
    cat <<EOF
Usage:
  sudo ./$PROGRAM_NAME --mode install
  sudo ./$PROGRAM_NAME --mode cert
  sudo ./$PROGRAM_NAME --mode certificate

Modes:
  --mode install       Install or reconfigure Caddy for Open WebUI
  --mode cert          Renew the fallback and change HTTPS certificate mode
  --mode certificate   Same as --mode cert
  -h, --help           Show this help

This script is interactive. With no options it only displays this help.

Install mode wizard:
  1. Selects active LAN IPv4 interfaces and discovers reverse hostnames.
  2. Ensures an internal self-signed fallback certificate exists.
  3. Configures HTTPS and either the fallback or a supplied certificate/key.
  4. Optionally configures a separate HTTP listener.
  5. Installs or updates Caddy and certifies both proxy and direct access.
  6. Prints every usable IP-address and discovered-hostname URL.

Certificate mode requires an existing project-managed Caddy proxy. It preserves
the LAN bindings, ports, upstream, and HTTP settings. It only renews/selects the
HTTPS certificate, updates the managed route, and restarts and verifies Caddy.
EOF
}

cancel() {
    printf '\nCancelled. No Caddy configuration was changed.\n'
    exit 0
}

if (( $# == 0 )); then
    usage
    exit 0
fi

while (( $# > 0 )); do
    case "$1" in
        --mode)
            (( $# >= 2 )) || die "--mode requires install, cert, or certificate."
            [[ -z "$MODE" ]] || die "Specify --mode only once."
            MODE="$2"
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

case "$MODE" in
    install) ;;
    cert|certificate) MODE='certificate' ;;
    *) die "--mode must be install, cert, or certificate." ;;
esac

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."
[[ -t 0 && -t 1 ]] || die "This setup wizard requires an interactive terminal."
[[ -d /run/systemd/system ]] || die "This host is not running systemd."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == 'ubuntu' ]] || die "This phase currently supports Ubuntu only."
[[ "${VERSION_ID:-}" == '24.04' ]] ||
    die "This release is not yet supported: ${PRETTY_NAME:-Ubuntu ${VERSION_ID:-unknown}}."

read_conf_value() {
    local file="$1"
    local key="$2"
    local line
    local value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        value="${line#*=}"
        if [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
        printf '%s\n' "$value"
        return 0
    done < "$file"

    return 0
}

load_openwebui_state() {
    [[ -r "$OPENWEBUI_STATE" ]] ||
        die "Open WebUI state is missing. Run 04-open-webui-setup.bash first."
    [[ "$(read_conf_value "$OPENWEBUI_STATE" PHASE)" == 'open-webui' ]] ||
        die "The phase 04 state file is invalid: $OPENWEBUI_STATE"
    [[ "$(read_conf_value "$OPENWEBUI_STATE" ADMIN_SETUP)" == 'complete' ]] ||
        die "Open WebUI administrator setup is incomplete. Finish phase 04 first."
    [[ "$(read_conf_value "$OPENWEBUI_STATE" CHAT_CERTIFIED)" == 'yes' ]] ||
        die "Open WebUI chat certification is incomplete. Finish phase 04 first."

    OPENWEBUI_PORT="$(read_conf_value "$OPENWEBUI_STATE" OPENWEBUI_PORT)"
    [[ "$OPENWEBUI_PORT" =~ ^[0-9]{1,5}$ ]] ||
        die "The phase 04 Open WebUI port is invalid."
    (( 10#$OPENWEBUI_PORT >= 1 && 10#$OPENWEBUI_PORT <= 65535 )) ||
        die "The phase 04 Open WebUI port is outside the valid range."
    OPENWEBUI_URL="http://127.0.0.1:$OPENWEBUI_PORT"
}

load_previous_defaults() {
    local host_pairs
    local hostname_value
    local index
    local interface_csv
    local ip_address
    local ip_csv
    local pair
    local -a saved_pairs=()
    local value

    [[ -r "$STATE_FILE" ]] || return 0
    [[ "$(read_conf_value "$STATE_FILE" PHASE)" == 'caddy-open-webui' ]] ||
        die "The existing phase 05 state file is invalid: $STATE_FILE"

    value="$(read_conf_value "$STATE_FILE" HTTPS_PORT)"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && HTTPS_PORT="$value"
    value="$(read_conf_value "$STATE_FILE" HTTP_PORT)"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && HTTP_PORT="$value"
    value="$(read_conf_value "$STATE_FILE" HTTP_ENABLED)"
    [[ "$value" == 'yes' || "$value" == 'no' ]] && HTTP_ENABLED="$value"
    value="$(read_conf_value "$STATE_FILE" CERT_MODE)"
    case "$value" in
        self-signed|internal) CERT_MODE='self-signed' ;;
        custom) CERT_MODE='custom' ;;
    esac

    ip_csv="$(read_conf_value "$STATE_FILE" SELECTED_IPS)"
    interface_csv="$(read_conf_value "$STATE_FILE" SELECTED_INTERFACES)"
    if [[ -n "$ip_csv" ]]; then
        IFS=',' read -r -a SELECTED_IPS <<< "$ip_csv"
    fi
    if [[ -n "$interface_csv" ]]; then
        IFS=',' read -r -a SELECTED_INTERFACES <<< "$interface_csv"
    fi

    BIND_MODE="$(read_conf_value "$STATE_FILE" BIND_MODE)"
    if [[ "$BIND_MODE" == 'all' ]]; then
        BIND_VALUE='0.0.0.0'
    elif (( ${#SELECTED_IPS[@]} > 0 )); then
        BIND_MODE='selected'
        BIND_VALUE="${SELECTED_IPS[*]}"
    fi

    SELECTED_HOSTNAMES=()
    for index in "${!SELECTED_IPS[@]}"; do
        SELECTED_HOSTNAMES+=('')
    done
    host_pairs="$(read_conf_value "$STATE_FILE" REVERSE_HOSTNAMES)"
    IFS=',' read -r -a saved_pairs <<< "$host_pairs"
    for pair in "${saved_pairs[@]}"; do
        ip_address="${pair%%=*}"
        hostname_value="${pair#*=}"
        [[ "$pair" == *=* && -n "$hostname_value" ]] || continue
        for index in "${!SELECTED_IPS[@]}"; do
            if [[ "${SELECTED_IPS[$index]}" == "$ip_address" ]]; then
                SELECTED_HOSTNAMES[$index]="$hostname_value"
            fi
        done
    done

    DISCOVERED_HOSTNAMES=()
    for hostname_value in "${SELECTED_HOSTNAMES[@]}"; do
        [[ -n "$hostname_value" ]] && DISCOVERED_HOSTNAMES+=("$hostname_value")
    done
}

verify_prerequisites() {
    local command_name
    local required_commands='awk cmp curl getent grep openssl sed sha256sum'

    if [[ "$MODE" == 'install' ]]; then
        required_commands+=' ip ss'
    fi
    for command_name in $required_commands; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required command is unavailable: $command_name"
    done
}

verify_certificate_mode_preconditions() {
    [[ -r "$STATE_FILE" ]] ||
        die "Certificate mode requires an existing phase 05 configuration. Run --mode install first."
    command -v caddy >/dev/null 2>&1 ||
        die "Caddy is not installed. Certificate mode never installs it; run --mode install first."
    systemctl cat caddy.service >/dev/null 2>&1 ||
        die "caddy.service does not exist. Run --mode install first."
    [[ -s "$CADDYFILE" ]] ||
        die "The existing Caddyfile is missing: $CADDYFILE"
    [[ -s "$CADDY_SNIPPET" ]] ||
        die "The managed Open WebUI reverse proxy is missing. Run --mode install first."
    grep -Fq "$CADDY_MARKER" "$CADDY_SNIPPET" ||
        die "$CADDY_SNIPPET is not managed by this project. Certificate mode will not edit it."
    grep -Eq "^[[:space:]]*reverse_proxy[[:space:]]+(http://)?(127\\.0\\.0\\.1|localhost):$OPENWEBUI_PORT([[:space:]]|$)" \
        "$CADDY_SNIPPET" ||
        die "The managed route no longer proxies to $OPENWEBUI_URL. Run --mode install to reconfigure it."
    grep -Fxq "$CADDY_IMPORT_LINE" "$CADDYFILE" ||
        die "The Caddyfile no longer imports the managed route. Run --mode install to repair it."
    (( ${#SELECTED_IPS[@]} > 0 )) ||
        die "The existing phase 05 state has no selected LAN addresses. Run --mode install again."
    [[ -n "$BIND_VALUE" ]] ||
        die "The existing phase 05 bind configuration is incomplete. Run --mode install again."
    [[ "$HTTPS_PORT" =~ ^[0-9]{1,5}$ ]] &&
        (( 10#$HTTPS_PORT >= 1 && 10#$HTTPS_PORT <= 65535 )) ||
        die "The existing phase 05 HTTPS port is invalid. Run --mode install again."
    [[ "$HTTP_ENABLED" == 'yes' || "$HTTP_ENABLED" == 'no' ]] ||
        die "The existing phase 05 HTTP setting is invalid. Run --mode install again."
    if [[ "$HTTP_ENABLED" == 'yes' ]]; then
        [[ "$HTTP_PORT" =~ ^[0-9]{1,5}$ ]] &&
            (( 10#$HTTP_PORT >= 1 && 10#$HTTP_PORT <= 65535 )) ||
            die "The existing phase 05 HTTP port is invalid. Run --mode install again."
    fi
}

verify_openwebui() {
    systemctl is-active --quiet open-webui.service ||
        die "open-webui.service is not active."
    curl --fail --silent --show-error --max-time 15 \
        --output /dev/null "$OPENWEBUI_URL/health" ||
        die "Open WebUI is unavailable at $OPENWEBUI_URL."
    curl --fail --silent --show-error --max-time 15 \
        --output /dev/null "$OPENWEBUI_URL/" ||
        die "The Open WebUI page does not load directly from loopback."
}

detect_active_ipv4() {
    local address
    local interface_name

    IF_NAMES=()
    IF_IPS=()
    while read -r interface_name address; do
        [[ -n "$interface_name" && -n "$address" ]] || continue
        [[ "$interface_name" == 'lo' ]] && continue
        [[ "$address" =~ ^127\. ]] && continue
        [[ "$address" =~ ^169\.254\. ]] && continue
        IF_NAMES+=("$interface_name")
        IF_IPS+=("$address")
    done < <(
        ip -o -4 addr show up scope global |
            awk '{split($4, parts, "/"); print $2, parts[1]}'
    )

    (( ${#IF_IPS[@]} > 0 )) ||
        die "No active non-loopback IPv4 addresses were found. Connect a LAN interface and retry."
}

print_interface_menu() {
    local index

    printf '\nActive IPv4 interfaces:\n\n'
    for index in "${!IF_IPS[@]}"; do
        printf '  %d) %-18s %s\n' "$((index + 1))" "${IF_NAMES[$index]}" "${IF_IPS[$index]}"
    done
    printf '  A) All active IPv4 addresses (Caddy wildcard bind 0.0.0.0)\n'
    printf '  Q) Cancel and quit\n'
}

build_selected_interfaces() {
    local index

    SELECTED_IPS=()
    SELECTED_INTERFACES=()
    for index in "${SELECTED_INDEXES[@]}"; do
        SELECTED_IPS+=("${IF_IPS[$index]}")
        SELECTED_INTERFACES+=("${IF_NAMES[$index]}")
    done
}

select_interfaces() {
    local answer
    local normalized
    local selection
    local token
    local index
    local existing_index
    local already_selected
    local numeric_token

    info "Select LAN interfaces"
    while true; do
        print_interface_menu
        printf '\nEnter one or more numbers separated by spaces or commas.\n'
        read -r -p "Selection: " selection

        case "${selection,,}" in
            q|quit|cancel) cancel ;;
            a|all)
                SELECTED_INDEXES=()
                for index in "${!IF_IPS[@]}"; do
                    SELECTED_INDEXES+=("$index")
                done
                BIND_MODE='all'
                ;;
            *)
                normalized="${selection//,/ }"
                SELECTED_INDEXES=()
                for token in $normalized; do
                    if [[ ! "$token" =~ ^[0-9]{1,5}$ ]]; then
                        warn "Invalid interface selection: $token"
                        SELECTED_INDEXES=()
                        break
                    fi
                    numeric_token=$((10#$token))
                    if (( numeric_token < 1 || numeric_token > ${#IF_IPS[@]} )); then
                        warn "Invalid interface selection: $token"
                        SELECTED_INDEXES=()
                        break
                    fi
                    index=$((numeric_token - 1))
                    already_selected='no'
                    for existing_index in "${SELECTED_INDEXES[@]}"; do
                        [[ "$existing_index" == "$index" ]] && already_selected='yes'
                    done
                    if [[ "$already_selected" == 'no' ]]; then
                        SELECTED_INDEXES+=("$index")
                    fi
                done
                (( ${#SELECTED_INDEXES[@]} > 0 )) || continue
                BIND_MODE='selected'
                ;;
        esac

        build_selected_interfaces
        printf '\nSelected addresses:\n'
        for index in "${!SELECTED_IPS[@]}"; do
            printf '  - %-18s %s\n' "${SELECTED_INTERFACES[$index]}" "${SELECTED_IPS[$index]}"
        done
        [[ "$BIND_MODE" == 'all' ]] &&
            printf 'Caddy bind address: 0.0.0.0 (all IPv4 interfaces)\n'

        read -r -p "Confirm this selection? [y=confirm / n=reselect / q=quit]: " answer
        case "${answer,,}" in
            y|yes) break ;;
            q|quit|cancel) cancel ;;
            *) printf 'Returning to the interface menu.\n' ;;
        esac
    done

    if [[ "$BIND_MODE" == 'all' ]]; then
        BIND_VALUE='0.0.0.0'
    else
        BIND_VALUE="${SELECTED_IPS[*]}"
    fi
}

discover_reverse_hostnames() {
    local hostname_value
    local ip_address
    local existing
    local candidate

    info "Discovering reverse hostnames"
    DISCOVERED_HOSTNAMES=()
    SELECTED_HOSTNAMES=()

    for ip_address in "${SELECTED_IPS[@]}"; do
        hostname_value="$(
            getent hosts "$ip_address" 2>/dev/null |
                awk -v wanted="$ip_address" '$1 == wanted {print $2; exit}' || true
        )"
        hostname_value="${hostname_value%.}"

        if [[ -n "$hostname_value" && "$hostname_value" != "$ip_address" ]]; then
            SELECTED_HOSTNAMES+=("$hostname_value")
            existing='no'
            for candidate in "${DISCOVERED_HOSTNAMES[@]}"; do
                [[ "$candidate" == "$hostname_value" ]] && existing='yes'
            done
            [[ "$existing" == 'yes' ]] || DISCOVERED_HOSTNAMES+=("$hostname_value")
            printf '  %s -> %s\n' "$ip_address" "$hostname_value"
        else
            SELECTED_HOSTNAMES+=('')
            printf '  %s -> no reverse hostname found\n' "$ip_address"
        fi
    done
}

certificate_covers_selected_names() {
    local certificate="$1"
    local hostname_value
    local ip_address

    [[ -s "$certificate" ]] || return 1
    openssl x509 -in "$certificate" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    for ip_address in "${SELECTED_IPS[@]}"; do
        openssl x509 -in "$certificate" -noout -checkip "$ip_address" >/dev/null 2>&1 || return 1
    done
    for hostname_value in "${DISCOVERED_HOSTNAMES[@]}"; do
        openssl x509 -in "$certificate" -noout -checkhost "$hostname_value" >/dev/null 2>&1 || return 1
    done
    return 0
}

generate_fallback_certificate() {
    local force_renewal="${1:-no}"
    local common_name
    local ext_file
    local hostname_value
    local ip_address
    local san_list=''
    local temp_dir

    info "Ensuring the internal self-signed fallback certificate"
    install -d -o root -g root -m 0700 "$CERT_DIR"

    if ! openssl x509 -in "$LOCAL_CA_CERT" -noout -checkend 2592000 >/dev/null 2>&1 ||
       ! openssl pkey -in "$LOCAL_CA_KEY" -noout -passin pass: >/dev/null 2>&1; then
        rm -f -- "$LOCAL_CA_CERT" "$LOCAL_CA_KEY" "$LOCAL_CA_SERIAL"
        rm -f -- "$FALLBACK_CERT" "$FALLBACK_LEAF_CERT" "$FALLBACK_KEY"
        openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
            -subj '/CN=ubuntu-llm-helper Open WebUI Local CA' \
            -addext 'basicConstraints=critical,CA:TRUE' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign' \
            -keyout "$LOCAL_CA_KEY" -out "$LOCAL_CA_CERT"
        chmod 0600 "$LOCAL_CA_KEY"
        chmod 0644 "$LOCAL_CA_CERT"
        CERT_CHANGED='yes'
        printf 'Created a new local root CA.\n'
    else
        printf 'Reusing the existing local root CA.\n'
    fi

    if [[ "$force_renewal" == 'yes' ]]; then
        rm -f -- "$FALLBACK_CERT" "$FALLBACK_LEAF_CERT" "$FALLBACK_KEY"
        printf 'Renewing the fallback server certificate.\n'
    fi

    if certificate_covers_selected_names "$FALLBACK_LEAF_CERT" &&
       validate_private_key_file "$FALLBACK_KEY" &&
       certificate_and_key_match "$FALLBACK_LEAF_CERT" "$FALLBACK_KEY"; then
        if [[ ! -s "$FALLBACK_CERT" ]]; then
            { printf '%s\n' "$(<"$FALLBACK_LEAF_CERT")"; printf '%s\n' "$(<"$LOCAL_CA_CERT")"; } \
                > "$FALLBACK_CERT"
            CERT_CHANGED='yes'
        fi
        printf 'Existing fallback certificate already covers the selected addresses and hostnames.\n'
        return 0
    fi

    for ip_address in "${SELECTED_IPS[@]}"; do
        san_list+="${san_list:+,}IP:$ip_address"
    done
    for hostname_value in "${DISCOVERED_HOSTNAMES[@]}"; do
        san_list+="${san_list:+,}DNS:$hostname_value"
    done
    common_name="${DISCOVERED_HOSTNAMES[0]:-${SELECTED_IPS[0]}}"

    temp_dir="$(mktemp -d /run/caddy-open-webui-cert.XXXXXX)"
    ext_file="$temp_dir/server.ext"
    {
        printf 'basicConstraints=critical,CA:FALSE\n'
        printf 'keyUsage=critical,digitalSignature,keyEncipherment\n'
        printf 'extendedKeyUsage=serverAuth\n'
        printf 'subjectAltName=%s\n' "$san_list"
    } > "$ext_file"

    openssl req -new -newkey rsa:2048 -nodes -sha256 \
        -subj "/CN=$common_name" \
        -keyout "$temp_dir/server.key" -out "$temp_dir/server.csr"
    openssl x509 -req -sha256 -days 825 \
        -in "$temp_dir/server.csr" \
        -CA "$LOCAL_CA_CERT" -CAkey "$LOCAL_CA_KEY" \
        -CAserial "$LOCAL_CA_SERIAL" -CAcreateserial \
        -extfile "$ext_file" -out "$temp_dir/server.crt"

    install -o root -g root -m 0600 "$temp_dir/server.key" "$FALLBACK_KEY"
    install -o root -g root -m 0644 "$temp_dir/server.crt" "$FALLBACK_LEAF_CERT"
    {
        printf '%s\n' "$(<"$temp_dir/server.crt")"
        printf '%s\n' "$(<"$LOCAL_CA_CERT")"
    } > "$FALLBACK_CERT"
    chmod 0644 "$FALLBACK_CERT"
    rm -rf -- "$temp_dir"
    CERT_CHANGED='yes'
    printf 'Generated a fallback certificate for the selected IP addresses and discovered hostnames.\n'
}

validate_certificate_file() {
    local certificate="$1"

    [[ -f "$certificate" && -r "$certificate" ]] || return 1
    openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || return 1
    openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1
}

validate_private_key_file() {
    local key_file="$1"

    [[ -f "$key_file" && -r "$key_file" ]] || return 1
    openssl pkey -in "$key_file" -noout -passin pass: >/dev/null 2>&1
}

certificate_and_key_match() {
    local certificate="$1"
    local key_file="$2"
    local certificate_hash
    local key_hash

    certificate_hash="$(openssl x509 -in "$certificate" -pubkey -noout |
        openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$key_file" -passin pass: -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
    [[ -n "$certificate_hash" && "$certificate_hash" == "$key_hash" ]]
}

confirm_custom_certificate_coverage() {
    local certificate="$1"
    local answer
    local covered=0
    local hostname_value
    local ip_address
    local missing=0

    printf '\nCertificate name coverage:\n'
    for ip_address in "${SELECTED_IPS[@]}"; do
        if openssl x509 -in "$certificate" -noout -checkip "$ip_address" >/dev/null 2>&1; then
            printf '  covered: %s\n' "$ip_address"
            covered=$((covered + 1))
        else
            printf '  MISSING: %s\n' "$ip_address"
            missing=$((missing + 1))
        fi
    done
    for hostname_value in "${DISCOVERED_HOSTNAMES[@]}"; do
        if openssl x509 -in "$certificate" -noout -checkhost "$hostname_value" >/dev/null 2>&1; then
            printf '  covered: %s\n' "$hostname_value"
            covered=$((covered + 1))
        else
            printf '  MISSING: %s\n' "$hostname_value"
            missing=$((missing + 1))
        fi
    done

    if (( missing == 0 )); then
        return 0
    fi
    if (( covered == 0 )); then
        warn "This certificate covers none of the selected IP addresses or discovered hostnames."
    else
        warn "Clients using a missing name will report a certificate-name mismatch."
    fi
    read -r -p "Use this certificate anyway? [y/N]: " answer
    yes_answer "$answer"
}

collect_custom_certificate() {
    local path_value

    while true; do
        read -r -p "Full path to certificate or PEM full chain [BACK]: " path_value
        [[ "${path_value^^}" == 'BACK' ]] && return 1
        if ! validate_certificate_file "$path_value"; then
            warn "That file is missing, unreadable, expired, or not a valid PEM X.509 certificate/full chain."
            continue
        fi
        CUSTOM_CERT_SOURCE="$path_value"
        break
    done

    while true; do
        read -r -p "Full path to the matching unencrypted private key [BACK]: " path_value
        [[ "${path_value^^}" == 'BACK' ]] && return 1
        if ! validate_private_key_file "$path_value"; then
            warn "That file is missing, unreadable, encrypted, or not a valid PEM private key."
            continue
        fi
        if ! certificate_and_key_match "$CUSTOM_CERT_SOURCE" "$path_value"; then
            warn "The private key does not match the certificate."
            continue
        fi
        CUSTOM_KEY_SOURCE="$path_value"
        break
    done

    if ! confirm_custom_certificate_coverage "$CUSTOM_CERT_SOURCE"; then
        CUSTOM_CERT_SOURCE=''
        CUSTOM_KEY_SOURCE=''
        return 1
    fi

    return 0
}

choose_certificate_mode() {
    local default_selection='1'
    local selection

    [[ "$CERT_MODE" == 'custom' ]] && default_selection='2'
    info "Select the HTTPS certificate"
    while true; do
        cat <<'EOF'
1) Internal self-signed fallback certificate
2) Another preinstalled certificate or PEM full chain and private key
Q) Cancel and quit

The certificate file may contain the leaf certificate plus intermediate chain.
The private key is supplied separately and must be unencrypted.
EOF
        read -r -p "Selection [$default_selection]: " selection
        selection="${selection:-$default_selection}"
        case "${selection,,}" in
            1|self|self-signed|internal)
                CERT_MODE='self-signed'
                ACTIVE_CERT="$FALLBACK_CERT"
                ACTIVE_KEY="$FALLBACK_KEY"
                break
                ;;
            2|custom|certificate)
                if collect_custom_certificate; then
                    CERT_MODE='custom'
                    ACTIVE_CERT="$CUSTOM_CERT"
                    ACTIVE_KEY="$CUSTOM_KEY"
                    break
                fi
                printf 'Returned to certificate selection.\n'
                ;;
            q|quit|cancel) cancel ;;
            *) warn "Enter 1, 2, or Q." ;;
        esac
    done
}

port_conflicts() {
    local port="$1"
    local include_udp="$2"
    local output

    output="$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)"
    if [[ "$include_udp" == 'yes' ]]; then
        output+=$'\n'
        output+="$(ss -H -lunp "sport = :$port" 2>/dev/null || true)"
    fi
    [[ -n "$output" ]] || return 1

    # A listener owned by the Caddy instance being reconfigured is not an
    # external conflict. Every other listener is reported.
    printf '%s\n' "$output" | grep -v '"caddy"' | grep -q .
}

show_port_conflicts() {
    local port="$1"
    local include_udp="$2"

    ss -H -ltnp "sport = :$port" 2>/dev/null || true
    if [[ "$include_udp" == 'yes' ]]; then
        ss -H -lunp "sport = :$port" 2>/dev/null || true
    fi
}

prompt_for_port() {
    local label="$1"
    local default_port="$2"
    local include_udp="$3"
    local forbidden_port="${4:-}"
    local answer
    local numeric_port
    local requested_port

    if port_conflicts "$default_port" "$include_udp"; then
        warn "Default $label port $default_port is already used by another process."
        show_port_conflicts "$default_port" "$include_udp"
        default_port=''
    fi

    while true; do
        if [[ -n "$default_port" ]]; then
            read -r -p "$label port [$default_port]: " requested_port
            requested_port="${requested_port:-$default_port}"
        else
            read -r -p "$label port: " requested_port
        fi
        [[ "${requested_port^^}" == 'QUIT' || "${requested_port^^}" == 'Q' ]] && cancel

        if [[ ! "$requested_port" =~ ^[0-9]{1,5}$ ]]; then
            warn "Enter a TCP port between 1 and 65535."
            continue
        fi
        numeric_port=$((10#$requested_port))
        if (( numeric_port < 1 || numeric_port > 65535 )); then
            warn "Enter a TCP port between 1 and 65535."
            continue
        fi
        if [[ -n "$forbidden_port" && "$numeric_port" == "$forbidden_port" ]]; then
            warn "$label cannot use the same port as HTTPS."
            continue
        fi

        if port_conflicts "$numeric_port" "$include_udp"; then
            warn "Port $numeric_port is already used by another process:"
            show_port_conflicts "$numeric_port" "$include_udp"
            read -r -p "Choose another port, force this port, or quit? [c/F/q]: " answer
            case "${answer,,}" in
                f|force)
                    warn "Caddy cannot start on port $numeric_port until the other listener is stopped."
                    FORCED_PORTS+=("$numeric_port")
                    ;;
                q|quit|cancel) cancel ;;
                *) continue ;;
            esac
        fi

        CHOSEN_PORT="$numeric_port"
        return 0
    done
}

configure_ports() {
    local answer

    info "Configure HTTPS"
    prompt_for_port 'HTTPS' "$HTTPS_PORT" 'yes'
    HTTPS_PORT="$CHOSEN_PORT"

    choose_certificate_mode

    info "Optional HTTP listener"
    read -r -p "Also configure unencrypted HTTP? [y/N]: " answer
    if yes_answer "$answer"; then
        HTTP_ENABLED='yes'
        prompt_for_port 'HTTP' "$HTTP_PORT" 'no' "$HTTPS_PORT"
        HTTP_PORT="$CHOSEN_PORT"
        warn "HTTP sign-in credentials and chat traffic are unencrypted on the LAN."
    else
        HTTP_ENABLED='no'
    fi
}

prepare_caddy_certificates() {
    getent group caddy >/dev/null 2>&1 ||
        die "The Caddy service group does not exist. Run --mode install first."
    install -d -o root -g caddy -m 0750 "$CERT_DIR"
    chown root:caddy "$LOCAL_CA_CERT" "$FALLBACK_CERT" "$FALLBACK_LEAF_CERT" "$FALLBACK_KEY"
    chmod 0644 "$LOCAL_CA_CERT" "$FALLBACK_CERT" "$FALLBACK_LEAF_CERT"
    chmod 0640 "$FALLBACK_KEY"
    chmod 0600 "$LOCAL_CA_KEY"

    if [[ "$CERT_MODE" == 'custom' ]]; then
        if [[ ! -s "$CUSTOM_CERT" ]] || ! cmp -s "$CUSTOM_CERT_SOURCE" "$CUSTOM_CERT"; then
            install -o root -g caddy -m 0644 "$CUSTOM_CERT_SOURCE" "$CUSTOM_CERT"
            CERT_CHANGED='yes'
        fi
        if [[ ! -s "$CUSTOM_KEY" ]] || ! cmp -s "$CUSTOM_KEY_SOURCE" "$CUSTOM_KEY"; then
            install -o root -g caddy -m 0640 "$CUSTOM_KEY_SOURCE" "$CUSTOM_KEY"
            CERT_CHANGED='yes'
        fi
    fi
}

install_caddy_and_certificates() {
    local backup
    local migrated_file

    info "Installing the Caddy package"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y caddy

    prepare_caddy_certificates

    install -d -o root -g root -m 0755 "$CADDY_CONFIG_DIR"
    if [[ -e "$CADDYFILE" ]] && grep -Fq "$CADDY_MARKER" "$CADDYFILE"; then
        backup="$CADDYFILE.before-open-webui.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CADDYFILE" "$backup"
        migrated_file="$(mktemp /etc/caddy/Caddyfile.migrate.XXXXXX)"
        awk -v marker="$CADDY_MARKER" '
            $0 == marker { skipping=1; next }
            skipping && /^[[:space:]]*}[[:space:]]*$/ { skipping=0; next }
            !skipping { print }
        ' "$CADDYFILE" > "$migrated_file"
        install -o root -g root -m 0644 "$migrated_file" "$CADDYFILE"
        rm -f -- "$migrated_file"
        CONFIG_CHANGED='yes'
        printf 'Migrated the legacy inline Open WebUI route; backup: %s\n' "$backup"
    fi

    if [[ ! -e "$CADDYFILE" ]]; then
        {
            printf '%s\n' "$CADDY_IMPORT_MARKER"
            printf '%s\n' "$CADDY_IMPORT_LINE"
        } > "$CADDYFILE"
        CONFIG_CHANGED='yes'
    elif ! grep -Fxq "$CADDY_IMPORT_LINE" "$CADDYFILE"; then
        backup="$CADDYFILE.before-open-webui.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CADDYFILE" "$backup"
        {
            printf '\n%s\n' "$CADDY_IMPORT_MARKER"
            printf '%s\n' "$CADDY_IMPORT_LINE"
        } >> "$CADDYFILE"
        CONFIG_CHANGED='yes'
        printf 'Preserved the existing Caddyfile; backup: %s\n' "$backup"
    fi
}

site_address() {
    local scheme="$1"
    local port="$2"
    local standard_port="$3"

    if [[ "$port" == "$standard_port" ]]; then
        printf '%s://' "$scheme"
    else
        printf '%s://:%s' "$scheme" "$port"
    fi
}

write_candidate_config() {
    local candidate_file="$1"
    local https_address
    local http_address

    https_address="$(site_address https "$HTTPS_PORT" 443)"
    {
        printf '%s\n' "$CADDY_MARKER"
        printf '%s {\n' "$https_address"
        printf '    bind %s\n' "$BIND_VALUE"
        printf '    tls %s %s\n' "$ACTIVE_CERT" "$ACTIVE_KEY"
        printf '    encode zstd gzip\n'
        printf '    reverse_proxy 127.0.0.1:%s\n' "$OPENWEBUI_PORT"
        printf '}\n'

        if [[ "$HTTP_ENABLED" == 'yes' ]]; then
            http_address="$(site_address http "$HTTP_PORT" 80)"
            printf '\n%s {\n' "$http_address"
            printf '    bind %s\n' "$BIND_VALUE"
            printf '    encode zstd gzip\n'
            printf '    reverse_proxy 127.0.0.1:%s\n' "$OPENWEBUI_PORT"
            printf '}\n'
        fi
    } > "$candidate_file"
}

install_managed_route() {
    local backup=''
    local candidate
    local candidate_file
    local manual_proxy=''

    if [[ -e "$CADDY_SNIPPET" ]] &&
       ! grep -Fq "$CADDY_MARKER" "$CADDY_SNIPPET"; then
        die "$CADDY_SNIPPET exists but is not managed by this project."
    fi

    if [[ ! -e "$CADDY_SNIPPET" ]]; then
        for candidate in "$CADDYFILE" "$CADDY_CONFIG_DIR"/*.caddy; do
            [[ -f "$candidate" ]] || continue
            [[ "$candidate" == "$CADDY_SNIPPET" ]] && continue
            if grep -Eq "^[[:space:]]*reverse_proxy[[:space:]]+(http://)?(127\\.0\\.0\\.1|localhost):$OPENWEBUI_PORT([[:space:]]|$)" \
                "$candidate"; then
                manual_proxy="$candidate"
                break
            fi
        done
        [[ -z "$manual_proxy" ]] ||
            die "An administrator-managed Open WebUI proxy already exists in $manual_proxy. Refusing to create a duplicate; move it to $CADDY_SNIPPET with the project marker if phase 05 should manage it."
    fi

    candidate_file="$(mktemp /etc/caddy/open-webui.caddy.XXXXXX)"
    write_candidate_config "$candidate_file"
    caddy validate --config "$candidate_file" --adapter caddyfile

    if [[ -s "$CADDY_SNIPPET" ]] && cmp -s "$candidate_file" "$CADDY_SNIPPET"; then
        printf 'The managed Open WebUI proxy already matches every selected setting; no route change is needed.\n'
        rm -f -- "$candidate_file"
        return 0
    fi

    if [[ -s "$CADDY_SNIPPET" ]]; then
        backup="$CADDY_SNIPPET.before.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CADDY_SNIPPET" "$backup"
    fi
    install -o root -g root -m 0644 "$candidate_file" "$CADDY_SNIPPET"
    rm -f -- "$candidate_file"

    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        if [[ -n "$backup" ]]; then
            cp -a "$backup" "$CADDY_SNIPPET"
        else
            rm -f -- "$CADDY_SNIPPET"
        fi
        die "The combined Caddy configuration was invalid; the prior route was restored."
    fi
    CONFIG_CHANGED='yes'
}

configure_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status | grep -q '^Status: active' || return 0

    info "Allowing selected Caddy ports through UFW"
    ufw allow "$HTTPS_PORT/tcp" comment 'Open WebUI HTTPS via Caddy'
    ufw allow "$HTTPS_PORT/udp" comment 'Open WebUI HTTP3 via Caddy'
    if [[ "$HTTP_ENABLED" == 'yes' ]]; then
        ufw allow "$HTTP_PORT/tcp" comment 'Open WebUI HTTP via Caddy'
    fi
}

restart_or_start_caddy() {
    info "Activating Caddy"
    systemctl enable caddy

    if [[ "$CONFIG_CHANGED" == 'yes' || "$CERT_CHANGED" == 'yes' ]]; then
        if ! systemctl restart caddy; then
            journalctl -u caddy -n 120 --no-pager 2>&1 || true
            if verify_openwebui; then
                die "Direct Open WebUI access works, but Caddy failed to restart. Review the Caddy errors above."
            fi
            die "Both Caddy and direct Open WebUI verification failed."
        fi
    elif ! systemctl is-active --quiet caddy; then
        systemctl start caddy
    else
        printf 'Caddy configuration and certificates are unchanged; no restart was needed.\n'
    fi
}

url_for() {
    local scheme="$1"
    local host="$2"
    local port="$3"
    local standard_port="$4"

    if [[ "$port" == "$standard_port" ]]; then
        printf '%s://%s' "$scheme" "$host"
    else
        printf '%s://%s:%s' "$scheme" "$host" "$port"
    fi
}

verify_caddy_proxy() {
    local ip_address="${SELECTED_IPS[0]}"
    local test_url

    info "Certifying direct and proxied Open WebUI access"
    verify_openwebui

    test_url="$(url_for https "$ip_address" "$HTTPS_PORT" 443)"
    if [[ "$CERT_MODE" == 'self-signed' ]]; then
        if ! curl --fail --silent --show-error --max-time 30 \
            --cacert "$LOCAL_CA_CERT" --output /dev/null "$test_url/"; then
            verify_openwebui || true
            die "Direct Open WebUI works, but the Caddy HTTPS connection failed: $test_url"
        fi
    else
        if ! curl --fail --silent --show-error --max-time 30 \
            --insecure --output /dev/null "$test_url/"; then
            verify_openwebui || true
            die "Direct Open WebUI works, but the Caddy HTTPS connection failed: $test_url"
        fi
        warn "The custom-certificate connectivity test bypassed client trust validation; deploy the appropriate CA chain to clients."
    fi

    if [[ "$HTTP_ENABLED" == 'yes' ]]; then
        test_url="$(url_for http "$ip_address" "$HTTP_PORT" 80)"
        if ! curl --fail --silent --show-error --max-time 30 \
            --output /dev/null "$test_url/"; then
            verify_openwebui || true
            die "Direct Open WebUI works, but the Caddy HTTP connection failed: $test_url"
        fi
    fi
}

record_state() {
    local host_pairs=''
    local hostname_value
    local ip_address
    local index
    local selected_interfaces
    local selected_ips

    selected_ips="$(IFS=,; printf '%s' "${SELECTED_IPS[*]}")"
    selected_interfaces="$(IFS=,; printf '%s' "${SELECTED_INTERFACES[*]}")"
    for index in "${!SELECTED_IPS[@]}"; do
        ip_address="${SELECTED_IPS[$index]}"
        hostname_value="${SELECTED_HOSTNAMES[$index]}"
        [[ -n "$hostname_value" ]] || continue
        host_pairs+="${host_pairs:+,}$ip_address=$hostname_value"
    done

    mkdir -p "$AI_STATE_DIR"
    chmod 0755 "$AI_STATE_DIR"
    {
        printf 'PHASE=%q\n' 'caddy-open-webui'
        printf 'MODE=%q\n' "$MODE"
        printf 'SELECTED_INTERFACES=%q\n' "$selected_interfaces"
        printf 'SELECTED_IPS=%q\n' "$selected_ips"
        printf 'BIND_MODE=%q\n' "$BIND_MODE"
        printf 'BIND_VALUE=%q\n' "$BIND_VALUE"
        printf 'REVERSE_HOSTNAMES=%q\n' "$host_pairs"
        printf 'HTTPS_PORT=%q\n' "$HTTPS_PORT"
        printf 'HTTP_ENABLED=%q\n' "$HTTP_ENABLED"
        printf 'HTTP_PORT=%q\n' "$HTTP_PORT"
        printf 'CERT_MODE=%q\n' "$CERT_MODE"
        printf 'CERT_FILE=%q\n' "$ACTIVE_CERT"
        printf 'KEY_FILE=%q\n' "$ACTIVE_KEY"
        printf 'FALLBACK_CA_CERT=%q\n' "$LOCAL_CA_CERT"
        printf 'FALLBACK_CERT=%q\n' "$FALLBACK_CERT"
        printf 'UPSTREAM_URL=%q\n' "$OPENWEBUI_URL"
        printf 'SERVICE_NAME=%q\n' 'caddy.service'
        printf 'CONFIGURED_AT=%q\n' "$(date --iso-8601=seconds)"
    } > "$STATE_FILE"
    chmod 0644 "$STATE_FILE"
}

print_summary() {
    local hostname_value
    local ip_address
    local index

    printf '\nCADDY PHASE COMPLETE\n\n'
    printf 'Bind mode:         %s\n' "$BIND_MODE"
    printf 'Bind address(es):  %s\n' "$BIND_VALUE"
    printf 'HTTPS port:        %s\n' "$HTTPS_PORT"
    printf 'Certificate mode:  %s\n' "$CERT_MODE"
    printf 'HTTP enabled:      %s\n' "$HTTP_ENABLED"
    [[ "$HTTP_ENABLED" == 'yes' ]] && printf 'HTTP port:         %s\n' "$HTTP_PORT"
    printf 'Upstream:          %s\n' "$OPENWEBUI_URL"
    printf 'Caddy service:     enabled and running\n'

    printf '\nHTTPS URLs:\n'
    for index in "${!SELECTED_IPS[@]}"; do
        ip_address="${SELECTED_IPS[$index]}"
        printf '  %s\n' "$(url_for https "$ip_address" "$HTTPS_PORT" 443)"
        hostname_value="${SELECTED_HOSTNAMES[$index]}"
        [[ -n "$hostname_value" ]] &&
            printf '  %s\n' "$(url_for https "$hostname_value" "$HTTPS_PORT" 443)"
    done

    if [[ "$HTTP_ENABLED" == 'yes' ]]; then
        printf '\nHTTP URLs:\n'
        for index in "${!SELECTED_IPS[@]}"; do
            ip_address="${SELECTED_IPS[$index]}"
            printf '  %s\n' "$(url_for http "$ip_address" "$HTTP_PORT" 80)"
            hostname_value="${SELECTED_HOSTNAMES[$index]}"
            [[ -n "$hostname_value" ]] &&
                printf '  %s\n' "$(url_for http "$hostname_value" "$HTTP_PORT" 80)"
        done
    fi

    printf '\nFallback trust certificate:\n  %s\n' "$LOCAL_CA_CERT"
    if [[ "$CERT_MODE" == 'self-signed' ]]; then
        printf 'Install that CA certificate on client devices to trust the HTTPS URLs.\n'
    fi

    cat <<EOF

Useful commands:

    sudo systemctl status caddy
    sudo journalctl -u caddy -f
    sudo ./$PROGRAM_NAME --mode certificate
EOF
}

load_openwebui_state
load_previous_defaults
verify_prerequisites
if [[ "$MODE" == 'certificate' ]]; then
    verify_certificate_mode_preconditions
fi
verify_openwebui

printf 'Operating system:  %s\n' "${PRETTY_NAME:-Ubuntu}"
printf 'Open WebUI:        %s\n' "$OPENWEBUI_URL"
printf 'Wizard mode:       %s\n' "$MODE"

if [[ "$MODE" == 'certificate' ]]; then
    printf 'Existing HTTPS:    %s\n' "$HTTPS_PORT"
    printf 'Existing bind:     %s\n' "$BIND_VALUE"
    printf 'HTTP configuration will be preserved without prompting.\n'

    choose_certificate_mode

    printf '\nCertificate maintenance selections:\n'
    printf '  HTTPS port:       %s (unchanged)\n' "$HTTPS_PORT"
    printf '  Bind:             %s (unchanged)\n' "$BIND_VALUE"
    printf '  Certificate:      %s\n' "$CERT_MODE"
    read -r -p "Apply this HTTPS certificate configuration? [y/N]: " final_confirmation
    yes_answer "$final_confirmation" || cancel

    if [[ "$CERT_MODE" == 'self-signed' ]]; then
        generate_fallback_certificate yes
    else
        generate_fallback_certificate
    fi
    prepare_caddy_certificates
    install_managed_route
    restart_or_start_caddy
    verify_caddy_proxy
    record_state
    print_summary
    exit 0
fi

detect_active_ipv4
select_interfaces
discover_reverse_hostnames
generate_fallback_certificate
configure_ports

printf '\nFinal selections:\n'
printf '  Bind:             %s\n' "$BIND_VALUE"
printf '  HTTPS port:       %s\n' "$HTTPS_PORT"
printf '  Certificate:      %s\n' "$CERT_MODE"
printf '  HTTP enabled:     %s\n' "$HTTP_ENABLED"
[[ "$HTTP_ENABLED" == 'yes' ]] && printf '  HTTP port:        %s\n' "$HTTP_PORT"
read -r -p "Apply this Caddy configuration? [y/N]: " final_confirmation
yes_answer "$final_confirmation" || cancel

install_caddy_and_certificates
install_managed_route
configure_firewall
restart_or_start_caddy
verify_caddy_proxy
record_state
print_summary
