#!/bin/bash

set -e
set -u
set -o pipefail

SRC=$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")
if ! type -t config_value &>/dev/null; then
    source "${SRC}/utils.sh"
fi
source "${SRC}/secure.sh"
source "${SRC}/prepare_android_img.sh"
source "${SRC}/build_opensbi.sh"
source "${SRC}/build_optee.sh"
source "${SRC}/build_uboot.sh"

function build_all {
    local config="$1"
    local clean="${2:-false}"
    local mode="${3:-release}"
    local out_dir=$(out_dir "${config}" "${mode}")

    if [[ "${clean}" == true ]] && [ -d "${out_dir}" ]; then
        rm -rf "${out_dir}"
    fi

    # SpacemiT K1 boot chain: OpenSBI -> (OP-TEE) -> U-Boot -> Android flash images
    build_opensbi "${config}" "${clean}" "${mode}"
    build_optee "${config}" "${clean}" "${mode}"
    build_uboot "${config}" "${clean}" "${mode}"
    prepare_android_images "${config}" "${mode}" "${out_dir}" "false"

    # secure package
    if [[ "${mode}" == "factory" ]]; then
        generate_secure_package "${config}" "${out_dir}"
    fi
}

if [ "$0" = "$BASH_SOURCE" ]; then
    main "$@"
fi
