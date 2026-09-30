#!/usr/bin/env bash
# tcp-optimize-tool :: robust installer for Debian / Ubuntu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh | bash
#
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh \
#     | bash -s -- apply
#
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh \
#     | bash -s -- diagnose
#
#   # Both forms are supported:
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh \
#     | bash -s -- diagnose aggressive
#
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh \
#     | bash -s -- "diagnose aggressive"
#
#   # Install/update only, do not run vps-ultimate-net.sh:
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh \
#     | bash -s -- install-only
#
# Optional:
#   TCP_OPTIMIZE_REF=v1.2.0
#   TCP_OPTIMIZE_SHA256=<sha256>

set -Eeuo pipefail

readonly REPO="ZhangLiangang/tcp-optimize-tool"
readonly REF="${TCP_OPTIMIZE_REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

readonly TARGET="/usr/local/sbin/vps-ultimate-net.sh"
readonly TARGET_DIR="/usr/local/sbin"
readonly BACKUP="${TARGET}.previous"

SUDO=()
TMP_FILE=""

log() {
    printf '[installer] %s\n' "$*"
}

warn() {
    printf '[installer] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[installer] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]]; then
        rm -f "$TMP_FILE" || true
    fi

    if [[ -e "${TARGET}.new" ]]; then
        "${SUDO[@]}" rm -f "${TARGET}.new" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'die "installation interrupted at line $LINENO"' ERR


# ------------------------------------------------------------
# Privilege handling
# ------------------------------------------------------------

setup_privileges() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        SUDO=()
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        SUDO=(sudo)
        log "root privileges will be obtained through sudo"
    else
        die "root privileges are required and sudo is not installed"
    fi
}


# ------------------------------------------------------------
# OS detection
# ------------------------------------------------------------

check_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found"

    # shellcheck disable=SC1091
    . /etc/os-release

    local id="${ID:-unknown}"
    local version="${VERSION_ID:-unknown}"
    local like="${ID_LIKE:-}"

    case "$id" in
        ubuntu|debian)
            log "detected ${PRETTY_NAME:-$id $version}"
            ;;
        *)
            if [[ " $like " == *" debian "* ]]; then
                warn "detected Debian-derived system: ${PRETTY_NAME:-$id}"
                warn "officially optimized for Debian and Ubuntu"
            else
                die "unsupported distribution: ${PRETTY_NAME:-$id}"
            fi
            ;;
    esac

    command -v apt-get >/dev/null 2>&1 \
        || die "apt-get not found; Debian/Ubuntu with apt is required"
}


# ------------------------------------------------------------
# apt handling
# ------------------------------------------------------------

apt_retry() {
    local attempt=1
    local max_attempts=3

    while true; do
        if "${SUDO[@]}" env \
            DEBIAN_FRONTEND=noninteractive \
            "$@"; then
            return 0
        fi

        if (( attempt >= max_attempts )); then
            return 1
        fi

        warn "APT command failed (attempt ${attempt}/${max_attempts}); retrying..."
        sleep $((attempt * 3))
        ((attempt++))
    done
}


ensure_deps() {
    local packages=(
        curl
        ca-certificates
        iproute2
        procps
        ethtool
        iperf3
    )

    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q '^Status: install ok installed$'; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log "all required packages are already installed"
        return
    fi

    log "missing packages: ${missing[*]}"
    log "updating APT metadata..."

    apt_retry apt-get update \
        || die "apt-get update failed"

    log "installing dependencies..."

    apt_retry apt-get install \
        -y \
        --no-install-recommends \
        "${missing[@]}" \
        || die "failed to install required packages"
}


# ------------------------------------------------------------
# Download
# ------------------------------------------------------------

download_main_script() {
    local url="${RAW_BASE}/vps-ultimate-net.sh"

    TMP_FILE="$(mktemp /tmp/vps-ultimate-net.XXXXXX)"

    log "downloading:"
    log "  $url"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --connect-timeout 10 \
        --max-time 120 \
        --retry 3 \
        --retry-delay 2 \
        "$url" \
        -o "$TMP_FILE" \
        || die "download failed"

    [[ -s "$TMP_FILE" ]] \
        || die "downloaded file is empty"

    log "download completed"
}


# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

validate_script() {
    log "checking Bash syntax..."

    bash -n "$TMP_FILE" \
        || die "downloaded script has invalid Bash syntax"

    local first_line
    first_line="$(head -n 1 "$TMP_FILE" || true)"

    if [[ "$first_line" != '#!'* ]]; then
        die "downloaded file does not appear to be a shell script"
    fi

    local expected="${TCP_OPTIMIZE_SHA256:-}"

    if [[ -n "$expected" ]]; then
        command -v sha256sum >/dev/null 2>&1 \
            || die "sha256sum not available"

        local actual
        actual="$(sha256sum "$TMP_FILE" | awk '{print $1}')"

        if [[ "$actual" != "$expected" ]]; then
            die "SHA256 mismatch
expected: $expected
actual:   $actual"
        fi

        log "SHA256 verification passed"
    fi
}


# ------------------------------------------------------------
# Install / update
# ------------------------------------------------------------

install_script() {
    "${SUDO[@]}" install \
        -d \
        -m 0755 \
        "$TARGET_DIR"

    # If identical, don't rewrite it.
    if [[ -r "$TARGET" ]] && cmp -s "$TMP_FILE" "$TARGET"; then
        log "vps-ultimate-net.sh is already up to date"
        return
    fi

    # Keep one known-good previous copy.
    if [[ -f "$TARGET" ]]; then
        log "backing up previous version:"
        log "  $BACKUP"

        "${SUDO[@]}" cp -a \
            "$TARGET" \
            "$BACKUP"
    fi

    # First install to a temporary path on the SAME filesystem.
    "${SUDO[@]}" install \
        -m 0755 \
        "$TMP_FILE" \
        "${TARGET}.new"

    # Atomic replacement.
    "${SUDO[@]}" mv -f \
        "${TARGET}.new" \
        "$TARGET"

    log "installed:"
    log "  $TARGET"
}


# ------------------------------------------------------------
# Argument normalization
# ------------------------------------------------------------

prepare_command() {
    RUN_ARGS=()

    if (( $# == 0 )); then
        RUN_ARGS=(apply)
        return
    fi

    # Convenience alias.
    if [[ "$1" == "install-only" ]]; then
        RUN_ARGS=()
        return
    fi

    # Current vps-ultimate-net.sh uses this as one subcommand.
    # Support both:
    #
    #   diagnose aggressive
    #
    # and:
    #
    #   "diagnose aggressive"
    #
    if [[ $# -eq 2 && "$1" == "diagnose" && "$2" == "aggressive" ]]; then
        RUN_ARGS=("diagnose aggressive")
        return
    fi

    RUN_ARGS=("$@")
}


# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------

run_main_script() {
    if (( ${#RUN_ARGS[@]} == 0 )); then
        log "installation/update completed; execution skipped"
        return
    fi

    printf '[installer] running: %q' "$TARGET"

    local arg
    for arg in "${RUN_ARGS[@]}"; do
        printf ' %q' "$arg"
    done

    printf '\n'

    exec "${SUDO[@]}" "$TARGET" "${RUN_ARGS[@]}"
}


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    setup_privileges
    check_os
    prepare_command "$@"
    ensure_deps
    download_main_script
    validate_script
    install_script
    run_main_script
}

main "$@"
