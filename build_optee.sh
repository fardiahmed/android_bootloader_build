#!/bin/bash
# OP-TEE OS for boards with an "optee" config section; tee.bin is staged into U-Boot, whose
# FIT then loads it to the OpenSBI trusted domain.

set -e
set -u
set -o pipefail

SRC=$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")
if ! type -t config_value &>/dev/null; then
    source "${SRC}/utils.sh"
fi

OPTEE_DIR="${ROOT}/optee_os"

function build_optee {
    local config="$1"
    local clean="${2:-false}"
    local mode="${3:-release}"
    local out_dir=$(out_dir "${config}" "${mode}")
    local platform=$(config_value "${config}" optee.platform)

    # No OP-TEE for this board: make sure U-Boot does not pick up a stale image.
    rm -f "${UBOOT_DIR}/tee.bin"
    [ -z "${platform}" ] && return 0
    [ -d "${OPTEE_DIR}" ] || error_exit "${OPTEE_DIR} missing (repo sync)"

    display_current_build "${config}" "optee" "${mode}"
    # The toolchain bin directory ships its own python3 without the cryptography module.
    local python3=$(command -v python3)
    clear_vars
    riscv64_env

    local build_dir="${out_dir}/optee"
    [[ "${clean}" == true ]] && rm -rf "${build_dir}"
    local debug_flags="CFG_TEE_CORE_LOG_LEVEL=2"
    [[ "${mode}" == "debug" ]] && debug_flags="CFG_TEE_CORE_LOG_LEVEL=3 CFG_TEE_CORE_DEBUG=y"

    make -C "${OPTEE_DIR}" ARCH=riscv PLATFORM="${platform}" \
         CROSS_COMPILE64="${CROSS_COMPILE}" PYTHON3="${python3}" \
         O="${build_dir}" ${debug_flags} -j$(nproc)

    cp -f "${build_dir}/core/tee.bin" "${out_dir}/tee.bin"
    cp -f "${build_dir}/core/tee.bin" "${UBOOT_DIR}/tee.bin"
    echo "OP-TEE built: ${out_dir}/tee.bin (TA dev kit: ${build_dir}/export-ta_rv64)"
    clear_vars
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main "$@"
fi
