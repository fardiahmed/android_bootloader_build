#!/bin/bash

set -e
set -u
set -o pipefail

SRC=$(dirname "$(readlink -e "$0")")
source "${SRC}/build_all.sh"
source "${SRC}/commit-binaries.sh"

# SpacemiT K1 projects in this repo tree
PROJECTS_AIOT=("opensbi" "pi-u-boot" "build-bootloaders")
PROJECTS_REMOTES="spacemit github"

function add_commit_msg {
    local -n commits_msg_ref="$1"
    local title_prefix="$2"
    local android_out="$3"
    local toplevel=""
    local commits_msg_value=""

    pushd "${android_out}"
    toplevel=$(git rev-parse --sq --show-toplevel)
    if [[ -v "commits_msg_ref[${toplevel}]" ]]; then
        commits_msg_value="${commits_msg_ref[${toplevel}]}"
        if ! [[ ${commits_msg_value} =~ ${title_prefix} ]]; then
            unset commits_msg_ref["${toplevel}"]
            commits_msg_ref+=(["${toplevel}"]="${commits_msg_value}/${title_prefix}")
        fi
    else
        commits_msg_ref+=(["${toplevel}"]="${title_prefix}")
    fi
    popd
}

function copy_binaries {
    local out="$1"
    local android_out="$2"
    local mode="$3"

    # OpenSBI firmware
    [ -f "${out}/fw_dynamic-${mode}.bin" ] && cp "${out}/fw_dynamic-${mode}.bin" "${android_out}/"
    [ -f "${out}/fw_dynamic.itb" ]         && cp -f "${out}/fw_dynamic.itb"     "${android_out}/"

    # U-Boot
    if [ -f "${out}/u-boot-${mode}.itb" ]; then
        cp "${out}/u-boot-${mode}.itb" "${android_out}/"
    elif [ -f "${out}/u-boot-${mode}.bin" ]; then
        cp "${out}/u-boot-${mode}.bin" "${android_out}/"
    fi
    [ -f "${out}/u-boot-spl-${mode}.bin" ] && cp "${out}/u-boot-spl-${mode}.bin" "${android_out}/"
    [ -f "${out}/u-boot-${mode}.dtb" ]     && cp "${out}/u-boot-${mode}.dtb"     "${android_out}/"
    [ -f "${out}/env-${mode}.bin" ]        && cp "${out}/env-${mode}.bin"       "${android_out}/"

    # Flash-ready files (factory blobs, partition layout)
    if [ -d "${out}/factory" ]; then
        mkdir -p "${android_out}/factory"
        cp -f "${out}/factory"/* "${android_out}/factory/"
    fi
    [ -f "${out}/partition_android.json" ] && cp -f "${out}/partition_android.json" "${android_out}/"
    [ -f "${out}/partition_nor.json" ]     && cp -f "${out}/partition_nor.json"     "${android_out}/"
    # logo.bmp comes from device/spacemit/k1 (copied by its Android.mk).
}

function usage {
    cat <<DELIM__
usage: $(basename "$0") [options]

$ $(basename "$0") --aosp=<path-to-android-root>

Options:
  --aosp     Android Root path (required)
  --commit   (OPTIONAL) commit binaries in AOSP
  --config   (OPTIONAL) release ONLY for this board config file
             (default: config/boards/spacemit-k1.yaml)
  --help     (OPTIONAL) display usage
  --mode     (OPTIONAL) [release|debug|factory] build only one mode
  --no-build (OPTIONAL) don't rebuild the images
  --silent   (OPTIONAL) silent build commands

DELIM__
}

function main {
    local aosp=""
    local commit=false
    local config=""
    local build=true
    local silent=false
    local mode_list=(debug release)

    local opts_args="aosp:,commit,config:,help,mode:,no-build,silent"
    local opts=$(getopt -o '' -l "${opts_args}" -- "$@")
    eval set -- "${opts}"

    while true; do
        case "$1" in
            --aosp) aosp=$(find_path "$2"); shift 2 ;;
            --commit) commit=true; shift ;;
            --config)
                config=$(find_path "$2")
                [ -z "${config}" ] && error_usage_exit "Cannot find board config file"
                shift 2 ;;
            --help) usage; exit 0 ;;
            --mode) mode_list=("$2"); shift 2 ;;
            --silent) silent=true; shift ;;
            --no-build) build=false; shift ;;
            --) shift; break ;;
        esac
    done

    # check arguments
    [ -z "${aosp}" ] && error_usage_exit "Cannot find Android Root Path"

    # set configs list
    declare -a configs
    if [ -n "${config}" ]; then
        configs=("${config}")
    else
        configs=("${SRC}"/config/boards/*.yaml)
    fi

    # build configs
    local binaries_path=""
    local out_dir=""
    declare -A commits_msg

    check_env

    pushd "${SRC}"
    for board_config in "${configs[@]}"; do
        binaries_path=$(config_value "${board_config}" android.binaries_path)

        for mode in "${mode_list[@]}"; do
            out_dir=$(out_dir "${board_config}" "${mode}")

            if [[ "${build}" == true ]]; then
                if [[ "${silent}" == true ]]; then
                    display_current_build "${board_config}" "all" "${mode}"
                    build_all "${board_config}" "true" "${mode}" &> /dev/null
                else
                    build_all "${board_config}" "true" "${mode}"
                fi
            fi
            ! [ -d "${aosp}/${binaries_path}" ] && mkdir -p "${aosp}/${binaries_path}"
            copy_binaries "${out_dir}" "${aosp}/${binaries_path}" "${mode}"
        done
        commit_title_prefix=$(board_name ${board_config})
        # Without --commit the binaries are build outputs (AOSP build.sh): no commit bookkeeping.
        if [[ "${commit}" == true ]]; then
            add_commit_msg commits_msg "${commit_title_prefix}" "${aosp}/${binaries_path}"
        fi

    done
    popd

    for abspath in "${!commits_msg[@]}"; do
        commit_title_prefix="${commits_msg[${abspath}]}"
        # we need the project name for commit_binaries(), not the
        # full filepath
        to_project=${abspath#${aosp}/}

        if [ "${commit}" == true ]; then
            commit_binaries --from-repo="${ROOT}" --from-projects="${PROJECTS_AIOT[*]}" \
                            --from-remotes="${PROJECTS_REMOTES}" \
                            --to-repo="${aosp}" --to-project="${to_project}" \
                            --title-prefix="${commit_title_prefix}"
        else
            commit_binaries --from-repo="${ROOT}" --from-projects="${PROJECTS_AIOT[*]}" \
                            --from-remotes="${PROJECTS_REMOTES}" \
                            --to-repo="${aosp}" --to-project="${to_project}" \
                            --title-prefix="${commit_title_prefix}" \
                            --dry-run
        fi
    done
}

main "$@"
