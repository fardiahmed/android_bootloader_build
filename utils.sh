#!/bin/bash
# Spacemit K1 Bootloader Build Utilities
# Adapted from TI build system for RISC-V

BUILD=$(dirname "$(readlink -e "$0")")
ROOT=$(readlink -e "${BUILD}/../")
OUT="${ROOT}/out"
TOOLCHAINS="${SYSTEM_WIDE_TOOLCHAINS:-${ROOT}/toolchains}"
MODES=("release" "debug" "factory")

INIT_PATH=$PATH

# Source directories (defaults). These may be overridden per board via the
# optional yaml keys opensbi.src / uboot.src, see resolve_src_dirs().
OPENSBI_DIR="${ROOT}/pi-opensbi"
UBOOT_DIR="${ROOT}/pi-u-boot"

# Defaults kept verbatim so resolve_src_dirs() can fall back to them when a
# board config does not set opensbi.src / uboot.src (i.e. the K1 case).
OPENSBI_DIR_DEFAULT="${OPENSBI_DIR}"
UBOOT_DIR_DEFAULT="${UBOOT_DIR}"

function pushd {
    command pushd "$@" > /dev/null
}

function popd {
    command popd > /dev/null
}

function find_path {
    local path="$1"
    local real_path=""
    if [ -e "${path}" ]; then
        real_path=$(readlink -e "${path}")
    fi
    echo "${real_path}"
}

function check_local_changes {
    local repo_path="$1" && shift
    local projects=("$@")

    for project in "${projects[@]}"; do
        if [ -d "${repo_path}/${project}" ]; then
            pushd "${repo_path}/${project}"
            git status > /dev/null 2>&1 || { popd; continue; }
            if ! git diff --quiet HEAD 2>/dev/null; then
                warning "Local changes detected in: ${project}"
            fi
            popd
        fi
    done
}

# RISC-V toolchain - use the official SpacemiT BSP toolchain (glibc, x86_64 host).
# v1.2.4 ships GCC 15.2.0 -- the exact compiler the SpacemiT K3 vendor BSP is
# built with, so U-Boot/OpenSBI codegen matches the vendor. Runs on glibc 2.35+.
# Triplet is riscv64-unknown-linux-gnu-. Tarball is .tar.xz.
RISCV_TOOLCHAIN_VERSION="v1.2.4"
RISCV_TOOLCHAIN_NAME="spacemit-toolchain-linux-glibc-x86_64-${RISCV_TOOLCHAIN_VERSION}"
RISCV_TOOLCHAIN_URL="http://archive.spacemit.com/toolchain/${RISCV_TOOLCHAIN_NAME}.tar.xz"

# Buildroot toolchain path (if available)
BUILDROOT_TOOLCHAIN="/srv/spacemit/buildroot/output/k1_v2/host/bin"

# Download and extract RISC-V toolchain
function download_riscv64_toolchain {
    local toolchain_dir="${TOOLCHAINS}/${RISCV_TOOLCHAIN_NAME}"
    local tarball="${TOOLCHAINS}/${RISCV_TOOLCHAIN_NAME}.tar.xz"

    if [ -d "${toolchain_dir}" ]; then
        echo "RISC-V toolchain already exists at ${toolchain_dir}"
        return 0
    fi

    echo "Downloading RISC-V toolchain from SpacemiT (${RISCV_TOOLCHAIN_VERSION})..."
    mkdir -p "${TOOLCHAINS}"

    if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
        error_exit "wget or curl is required to download toolchain"
    fi

    if command -v wget &> /dev/null; then
        wget -q --show-progress -O "${tarball}" "${RISCV_TOOLCHAIN_URL}"
    else
        curl -L -# -o "${tarball}" "${RISCV_TOOLCHAIN_URL}"
    fi

    echo "Extracting toolchain..."
    tar -xJf "${tarball}" -C "${TOOLCHAINS}"

    rm -f "${tarball}"
    echo "RISC-V toolchain installed to ${toolchain_dir}"
}

# Check if a toolchain works (glibc compatibility)
function check_toolchain_works {
    local gcc_path="$1"
    if [ -x "${gcc_path}" ]; then
        # Try to run gcc --version to check glibc compatibility
        "${gcc_path}" --version &> /dev/null
        return $?
    fi
    return 1
}

# RISC-V 64-bit cross-compiler
function riscv64_env {
    local toolchain_dir="${TOOLCHAINS}/${RISCV_TOOLCHAIN_NAME}"

    # Try system toolchain first
    if command -v riscv64-linux-gnu-gcc &> /dev/null; then
        if check_toolchain_works "$(command -v riscv64-linux-gnu-gcc)"; then
            export CROSS_COMPILE=riscv64-linux-gnu-
            export ARCH=riscv
            return
        fi
    fi

    if command -v riscv64-unknown-linux-gnu-gcc &> /dev/null; then
        if check_toolchain_works "$(command -v riscv64-unknown-linux-gnu-gcc)"; then
            export CROSS_COMPILE=riscv64-unknown-linux-gnu-
            export ARCH=riscv
            return
        fi
    fi

    # Try buildroot toolchain (check glibc compatibility)
    if [ -x "${BUILDROOT_TOOLCHAIN}/riscv64-unknown-linux-gnu-gcc" ]; then
        if check_toolchain_works "${BUILDROOT_TOOLCHAIN}/riscv64-unknown-linux-gnu-gcc"; then
            export PATH="${BUILDROOT_TOOLCHAIN}:$PATH"
            export CROSS_COMPILE=riscv64-unknown-linux-gnu-
            export ARCH=riscv
            return
        else
            warning "Buildroot toolchain found but incompatible with system glibc"
        fi
    fi

    # Try downloaded SpacemiT toolchain
    if [ -d "${toolchain_dir}/bin" ]; then
        if check_toolchain_works "${toolchain_dir}/bin/riscv64-unknown-linux-gnu-gcc"; then
            export PATH="${toolchain_dir}/bin:$PATH"
            export CROSS_COMPILE=riscv64-unknown-linux-gnu-
            export ARCH=riscv
            return
        fi
    fi

    # Download toolchain
    echo "RISC-V toolchain not found or incompatible, downloading SpacemiT toolchain..."
    download_riscv64_toolchain
    if [ -d "${toolchain_dir}/bin" ]; then
        export PATH="${toolchain_dir}/bin:$PATH"
        export CROSS_COMPILE=riscv64-unknown-linux-gnu-
        export ARCH=riscv
    else
        error_exit "Failed to setup RISC-V toolchain"
    fi
}

function check_riscv64 {
    local toolchain_dir="${TOOLCHAINS}/${RISCV_TOOLCHAIN_NAME}"

    # Check if RISC-V toolchain exists
    if command -v riscv64-linux-gnu-gcc &> /dev/null; then
        return 0
    elif command -v riscv64-unknown-linux-gnu-gcc &> /dev/null; then
        return 0
    elif [ -x "${BUILDROOT_TOOLCHAIN}/riscv64-unknown-linux-gnu-gcc" ]; then
        return 0
    elif [ -d "${toolchain_dir}/bin" ]; then
        return 0
    else
        warning "RISC-V toolchain not found in PATH or ${TOOLCHAINS}"
        warning "It will be downloaded automatically when building"
        return 1
    fi
}

# Legacy ARM functions (kept for compatibility, but not used for Spacemit)
function gnueabihf_env {
    export PATH="${TOOLCHAINS}/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin:$PATH"
    export CROSS_COMPILE=arm-none-linux-gnueabihf-
}

function aarch64_env {
    export PATH="${TOOLCHAINS}/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu/bin:$PATH"
    export CROSS_COMPILE=aarch64-none-linux-gnu-
    export CROSS_COMPILE64=aarch64-none-linux-gnu-
}

function avbtool_env {
    if [ -d "${ROOT}/prebuilts/build-tools/linux-x86/bin/" ]; then
        export PATH="${ROOT}/prebuilts/build-tools/linux-x86/bin/:$PATH"
    fi
}

function clear_vars {
    export PATH=$INIT_PATH
    unset ARCH
    unset CROSS_COMPILE
}

function check_env {
    # out directory
    ! [ -d "${OUT}" ] && mkdir -p "${OUT}"

    # toolchains directory
    ! [ -d "${TOOLCHAINS}" ] && mkdir -p "${TOOLCHAINS}"

    # Check RISC-V toolchain
    check_riscv64 || true
}

function config_value {
    local value=$(cat "$1" | shyaml --quiet get-value "$2" 2>/dev/null)
    echo "${value}"
}

# Resolve OPENSBI_DIR / UBOOT_DIR from the board config.
#
# A board yaml may set optional keys opensbi.src / uboot.src pointing at the
# source tree to build (absolute, or relative to ROOT = build-bootloaders/..).
# When a key is absent the historical default is kept (pi-opensbi / pi-u-boot),
# so the K1 config is unaffected. Both variables are exported so the helper
# scripts sourced later (prepare_android_img.sh) observe the same values.
function resolve_src_dirs {
    local config="$1"
    local opensbi_src=$(config_value "${config}" opensbi.src)
    local uboot_src=$(config_value "${config}" uboot.src)

    if [ -n "${opensbi_src}" ]; then
        case "${opensbi_src}" in
            /*) OPENSBI_DIR="${opensbi_src}" ;;
            *)  OPENSBI_DIR="${ROOT}/${opensbi_src}" ;;
        esac
    else
        OPENSBI_DIR="${OPENSBI_DIR_DEFAULT}"
    fi

    if [ -n "${uboot_src}" ]; then
        case "${uboot_src}" in
            /*) UBOOT_DIR="${uboot_src}" ;;
            *)  UBOOT_DIR="${ROOT}/${uboot_src}" ;;
        esac
    else
        UBOOT_DIR="${UBOOT_DIR_DEFAULT}"
    fi

    export OPENSBI_DIR UBOOT_DIR
}

function board_name {
    local yaml_config=$(basename "$1")
    echo "${yaml_config%.yaml}"
}

function out_dir {
    local board=$(board_name "$1")
    local mode="${2:-release}"

    echo "${OUT}/${board}/${mode}"
}

function display_current_build {
    local board=$(board_name "$1")
    local build="$2"
    local mode="$3"

    printf "\n"
    printf "%0.s-" {1..20}
    printf "> Build %s: %s - %s <" "${build}" "${board}" "${mode}"
    printf "%0.s-" {1..20}
    printf "\n"
}

function usage {
    cat <<DELIM__
usage: $(basename "$0") [options]

$ $(basename "$0") --config=config/boards/spacemit-k1.yaml

Options:
  --config   board config file
  --clean    (OPTIONAL) clean before build
  --mode     (OPTIONAL) [release|debug|factory] mode (default: release)
  --help     (OPTIONAL) display usage
DELIM__
}

function warning {
    local warning="$1"
    printf "\033[0;33mWARNING:\033[0m ${warning}\n"
}

function error {
    local error="$1"
    printf "\033[0;31mERROR:\033[0m ${error}\n\n"
}

function error_exit {
    error "$1"
    exit 1
}

function error_usage_exit {
    error "$1"
    usage
    exit 1
}

function main {
    local script=$(basename "$0")
    local build="${script%.*}"
    local clean=false
    local config=""
    local mode="release"

    local opts_args="clean,config:,help,mode:"
    local opts=$(getopt -o '' -l "${opts_args}" -- "$@")
    eval set -- "${opts}"

    while true; do
        case "$1" in
            --config) config=$(find_path "$2"); shift 2 ;;
            --clean) clean=true; shift ;;
            --mode) mode="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            --) shift; break ;;
        esac
    done

    # check arguments
    [ -z "${config}" ] &&  error_usage_exit "Cannot find board config file"
    ! [[ " ${MODES[*]} " =~ " ${mode} " ]] && error_usage_exit "${mode} mode not supported"

    # build
    check_env
    ${build} "${config}" "${clean}" "${mode}"
}
