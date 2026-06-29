#!/bin/bash
# Build OpenSBI for Spacemit K1

set -e
set -u
set -o pipefail

SRC=$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")
if ! type -t config_value &>/dev/null; then
    source "${SRC}/utils.sh"
fi

function build_opensbi {
    local config="$1"
    local clean="${2:-false}"
    local mode="${3:-release}"
    local out_dir=$(out_dir "${config}" "${mode}")

    # Pick the OpenSBI source tree (opensbi.src override, else pi-opensbi)
    resolve_src_dirs "${config}"

    display_current_build "${config}" "opensbi" "${mode}"

    # Get config values
    local platform=$(config_value "${config}" opensbi.platform)
    local extra_flags=$(config_value "${config}" opensbi.flags)

    # Default platform for Spacemit K1
    [ -z "${platform}" ] && platform="generic"

    # Setup environment
    clear_vars
    riscv64_env

    mkdir -p "${out_dir}"

    pushd "${OPENSBI_DIR}"

    # Clean if requested. Use distclean (not just clean) to wipe build/.config
    # too — otherwise a stale .config generated from the default upstream
    # `defconfig` (which sets CONFIG_PLATFORM_SPACEMIT_K1PRO=y) sticks around
    # and the subsequent `make … PLATFORM_DEFCONFIG=k1_defconfig` does not
    # regenerate it because timestamps already satisfy the make rule.
    if [[ "${clean}" == true ]]; then
        make PLATFORM="${platform}" distclean || true
    fi

    # Get defconfig from board config or use default
    local defconfig=$(config_value "${config}" opensbi.defconfig)
    [ -z "${defconfig}" ] && defconfig="k1_defconfig"

    # Build flags based on mode
    local debug_flags=""
    if [[ "${mode}" == "debug" ]]; then
        debug_flags="DEBUG=1"
    fi

    # Build OpenSBI (PLATFORM_DEFCONFIG loads the config automatically)
    make PLATFORM="${platform}" \
         PLATFORM_DEFCONFIG="${defconfig}" \
         FW_FDT_PATH="" \
         FW_PAYLOAD_PATH="" \
         ${debug_flags} \
         ${extra_flags} \
         -j$(nproc)

    # Copy output - OpenSBI generates fw_dynamic.bin
    local fw_dynamic="build/platform/${platform}/firmware/fw_dynamic.bin"
    if [ -f "${fw_dynamic}" ]; then
        cp "${fw_dynamic}" "${out_dir}/fw_dynamic-${mode}.bin"
        echo "OpenSBI built: ${out_dir}/fw_dynamic-${mode}.bin"
    else
        error_exit "OpenSBI build failed - fw_dynamic.bin not found"
    fi

    popd
    clear_vars
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main "$@"
fi
