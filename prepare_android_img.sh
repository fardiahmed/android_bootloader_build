#!/bin/bash
# Prepare Android images for Spacemit K1
# Based on Buildroot's prepare_img.sh

set -e
set -u
set -o pipefail

SRC=$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")
if ! type -t config_value &>/dev/null; then
    source "${SRC}/utils.sh"
fi

# Default paths
UBOOT_DIR="${UBOOT_DIR:-$(dirname "${SRC}")/pi-u-boot}"
CONFIG_DIR="${SRC}/config"

function usage {
    echo "Usage: $0 --config=<board-config.yaml> [--mode=release|debug] [--out=<output-dir>]"
    echo ""
    echo "Options:"
    echo "  --config=FILE     Board configuration YAML file (required)"
    echo "  --mode=MODE       Build mode: release or debug (default: debug)"
    echo "  --out=DIR         Output directory (default: auto from config)"
    echo "  --sdcard          Generate sdcard image using genimage"
    echo "  --help            Show this help"
    exit 1
}

function prepare_factory_files {
    local out_dir="$1"
    local factory_dir="${out_dir}/factory"

    echo "Preparing factory files..."
    mkdir -p "${factory_dir}"

    # Copy FSBL and bootinfo from U-Boot build
    if [ -f "${UBOOT_DIR}/FSBL.bin" ]; then
        cp -f "${UBOOT_DIR}/FSBL.bin" "${factory_dir}/"
    else
        error_exit "FSBL.bin not found in ${UBOOT_DIR}"
    fi

    # Copy bootinfo files. The exact set is board-specific: K1 emits
    # bootinfo_{spinor,spinand,emmc,sd}.bin, K3 emits
    # bootinfo_{spinor,spinand,block}.bin. Require at least one rather than a
    # specific medium so the step is not tied to a single SoC.
    local bootinfo_count=0
    for bootinfo in "${UBOOT_DIR}"/bootinfo_*.bin; do
        if [ -f "${bootinfo}" ]; then
            cp -f "${bootinfo}" "${factory_dir}/"
            bootinfo_count=$((bootinfo_count + 1))
        fi
    done

    if [ "${bootinfo_count}" -eq 0 ]; then
        error_exit "no bootinfo_*.bin found in ${UBOOT_DIR}"
    fi

    # Optional EC RW firmware (K3 Pico-ITX CrosEC, flashed via "oem ec:flash").
    # Board-agnostic and best-effort: only staged when the source blob exists.
    local ec_bin="${EC_BIN:-${ROOT}/../k3-buildroot-sdk/buildroot-ext/board/spacemit/k3/ec.bin}"
    if [ -f "${ec_bin}" ]; then
        cp -f "${ec_bin}" "${factory_dir}/ec.bin"
        echo "Staged EC firmware ${ec_bin}"
    fi

    echo "Factory files prepared in ${factory_dir}"
}

function prepare_bootloader_files {
    local out_dir="$1"
    local mode="$2"

    echo "Preparing bootloader files..."

    # Rename files to standard names (remove -debug/-release suffix)
    if [ -f "${out_dir}/fw_dynamic-${mode}.bin" ]; then
        # For now just copy, later we may need to wrap in ITB
        cp -f "${out_dir}/fw_dynamic-${mode}.bin" "${out_dir}/fw_dynamic.bin"
    fi

    if [ -f "${out_dir}/u-boot-${mode}.itb" ]; then
        cp -f "${out_dir}/u-boot-${mode}.itb" "${out_dir}/u-boot.itb"
    fi

    if [ -f "${out_dir}/env-${mode}.bin" ]; then
        cp -f "${out_dir}/env-${mode}.bin" "${out_dir}/env.bin"
    fi

    echo "Bootloader files prepared"
}

function create_fw_dynamic_itb {
    local out_dir="$1"
    local fw_bin="${out_dir}/fw_dynamic.bin"
    local fw_itb="${out_dir}/fw_dynamic.itb"

    if [ ! -f "${fw_bin}" ]; then
        echo "Warning: fw_dynamic.bin not found, skipping ITB creation"
        return 0
    fi

    echo "Creating fw_dynamic.itb..."

    # Create ITS file for fw_dynamic
    local its_file="${out_dir}/fw_dynamic.its"
    cat > "${its_file}" << 'EOF'
/dts-v1/;

/ {
    description = "OpenSBI fw_dynamic";
    #address-cells = <2>;

    images {
        opensbi {
            description = "OpenSBI fw_dynamic";
            data = /incbin/("fw_dynamic.bin");
            type = "firmware";
            arch = "riscv";
            os = "opensbi";
            load = <0x0 0x0>;
            entry = <0x0 0x0>;
        };
    };

    configurations {
        default = "config-1";
        config-1 {
            description = "OpenSBI fw_dynamic";
            firmware = "opensbi";
        };
    };
};
EOF

    # Generate ITB using mkimage
    pushd "${out_dir}" > /dev/null
    if command -v mkimage &> /dev/null; then
        mkimage -f fw_dynamic.its fw_dynamic.itb
        echo "Created: ${fw_itb}"
    else
        echo "Warning: mkimage not found, using raw fw_dynamic.bin"
        cp -f fw_dynamic.bin fw_dynamic.itb
    fi
    popd > /dev/null
}

function copy_partition_configs {
    local out_dir="$1"

    echo "Copying partition configurations..."

    # Copy Android partition config
    if [ -f "${CONFIG_DIR}/partition_android.json" ]; then
        cp -f "${CONFIG_DIR}/partition_android.json" "${out_dir}/"
    fi

    # Copy SPI-NOR bootloader layout (MTD) for NOR-boot boards (MUSE-Pi-Pro)
    if [ -f "${CONFIG_DIR}/partition_nor.json" ]; then
        cp -f "${CONFIG_DIR}/partition_nor.json" "${out_dir}/"
    fi

    # Create size-based partition links for fastboot
    # These are typically partition_<blk-size>.json
    if [ -f "${out_dir}/partition_android.json" ]; then
        # Common block sizes: 512B sectors, so 16GB = 16384M, etc.
        ln -sf partition_android.json "${out_dir}/partition_16384M.json" 2>/dev/null || true
        ln -sf partition_android.json "${out_dir}/partition_32768M.json" 2>/dev/null || true
        ln -sf partition_android.json "${out_dir}/partition_65536M.json" 2>/dev/null || true
    fi

    echo "Partition configs copied"
}

function create_fastboot_yaml {
    local out_dir="$1"
    local yaml_file="${out_dir}/fastboot.yaml"

    echo "Creating fastboot.yaml..."

    cat > "${yaml_file}" << 'EOF'
version: 1.0
support:
  - 'k1x'
  - 'k1pro'
actions:

  - getvar:
      args: 'version-brom'
      set: 'version'
      skip_fail: true
      timeout:
        seconds: 1

  - stage:
      file: 'factory/FSBL.bin'
      skip_when: "not temp.version"
      timeout:
        minutes: 2

  - continue:
      skip_when: "not temp.version"
      timeout:
        seconds: 1

  - stage:
      file: 'u-boot.itb'
      skip_when: "not temp.version"
      timeout:
        minutes: 2
      retry: 3

  - continue:
      skip_when: "not temp.version"
      timeout:
        seconds: 1

  - getvar:
      args: 'mtd-size'
      set_var: 'size0'
      timeout:
        seconds: 1

  - getvar:
      args: 'blk-size'
      set_var: 'size1'
      timeout:
        seconds: 1

  - multi_flash:
      timeout:
        minutes: 30
      retry: 3
      relate_partition: ['partition_{size0}.json', 'partition_{size1}.json']
EOF

    echo "Created: ${yaml_file}"
}

function generate_genimage_cfg {
    local out_dir="$1"
    local partition_json="${out_dir}/partition_android.json"
    local genimage_cfg="${out_dir}/genimage.cfg"
    local image_name="android-k1-sdcard.img"

    echo "Generating genimage.cfg..."

    if [ ! -f "${partition_json}" ]; then
        echo "Warning: partition_android.json not found, skipping genimage.cfg"
        return 0
    fi

    python3 "${SRC}/gen_imgcfg.py" \
        -i "${partition_json}" \
        -n "${image_name}" \
        -o "${genimage_cfg}"
}

function generate_sdcard_image {
    local out_dir="$1"
    local genimage_cfg="${out_dir}/genimage.cfg"

    if [ ! -f "${genimage_cfg}" ]; then
        echo "Warning: genimage.cfg not found, skipping sdcard image"
        return 0
    fi

    echo "Generating sdcard image..."

    # Check for genimage tool
    local genimage_cmd=""
    if command -v genimage &> /dev/null; then
        genimage_cmd="genimage"
    elif [ -x "/srv/spacemit/buildroot/output/k1_v2/host/bin/genimage" ]; then
        genimage_cmd="/srv/spacemit/buildroot/output/k1_v2/host/bin/genimage"
    else
        echo "Warning: genimage not found, skipping sdcard image generation"
        echo "Install genimage or use Buildroot's host tools"
        return 0
    fi

    local tmp_dir=$(mktemp -d)
    local root_dir="${tmp_dir}/root"
    mkdir -p "${root_dir}"

    # Run genimage
    ${genimage_cmd} \
        --rootpath "${root_dir}" \
        --tmppath "${tmp_dir}/tmp" \
        --inputpath "${out_dir}" \
        --outputpath "${out_dir}" \
        --config "${genimage_cfg}"

    rm -rf "${tmp_dir}"

    echo "Sdcard image generated in ${out_dir}"
}

function create_flash_zip {
    local out_dir="$1"
    local config="$2"
    local zip_file="${out_dir}/android-k1-flash.zip"

    echo "Creating flash archive..."

    pushd "${out_dir}" > /dev/null

    # List of files to include
    local files=(
        "fw_dynamic.itb"
        "u-boot.itb"
        "env.bin"
        "partition_android.json"
        "partition_*.json"
        "fastboot.yaml"
        "genimage.cfg"
    )

    # Add factory directory
    local zip_args=""
    for f in "${files[@]}"; do
        if ls ${f} 1>/dev/null 2>&1; then
            zip_args="${zip_args} ${f}"
        fi
    done

    if [ -d "factory" ]; then
        zip_args="${zip_args} -r factory"
    fi

    if [ -n "${zip_args}" ]; then
        rm -f "${zip_file}"
        zip "${zip_file}" ${zip_args} 2>/dev/null || true
        echo "Created: ${zip_file}"
    fi

    popd > /dev/null
}

function prepare_android_images {
    local config="$1"
    local mode="${2:-debug}"
    local out_dir="${3:-}"
    local gen_sdcard="${4:-false}"

    if [ -z "${out_dir}" ]; then
        out_dir=$(out_dir "${config}" "${mode}")
    fi

    # Pick the U-Boot source tree (uboot.src override, else pi-u-boot) so the
    # factory blobs are read from the right tree. resolve_src_dirs may already
    # have run in build_uboot; calling it again is idempotent.
    if type -t resolve_src_dirs &>/dev/null; then
        resolve_src_dirs "${config}"
    fi

    echo "============================================"
    echo "Preparing Android images"
    echo "  Config: ${config}"
    echo "  Mode: ${mode}"
    echo "  Output: ${out_dir}"
    echo "============================================"

    # Prepare factory files (FSBL, bootinfo)
    prepare_factory_files "${out_dir}"

    # Rename bootloader files
    prepare_bootloader_files "${out_dir}" "${mode}"

    # Create fw_dynamic.itb from fw_dynamic.bin
    create_fw_dynamic_itb "${out_dir}"

    # Copy partition configs
    copy_partition_configs "${out_dir}"

    # Create fastboot.yaml
    create_fastboot_yaml "${out_dir}"

    # Generate genimage.cfg
    generate_genimage_cfg "${out_dir}"

    # Optionally generate sdcard image
    if [ "${gen_sdcard}" = "true" ]; then
        generate_sdcard_image "${out_dir}"
    fi

    # Create flash archive
    create_flash_zip "${out_dir}" "${config}"

    echo ""
    echo "============================================"
    echo "Android images prepared successfully!"
    echo "Output directory: ${out_dir}"
    echo ""
    echo "Files:"
    ls -la "${out_dir}/"
    echo ""
    echo "To flash using titan tool:"
    echo "  titan -d k1 -w --images ${out_dir}"
    echo "============================================"
}

function prepare_android_main {
    local config=""
    local mode="debug"
    local out_dir=""
    local gen_sdcard="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --config=*)
                config="${1#*=}"
                shift
                ;;
            --mode=*)
                mode="${1#*=}"
                shift
                ;;
            --out=*)
                out_dir="${1#*=}"
                shift
                ;;
            --sdcard)
                gen_sdcard="true"
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [ -z "${config}" ]; then
        echo "Error: --config is required"
        usage
    fi

    if [ ! -f "${config}" ]; then
        # Try relative to config directory
        if [ -f "${CONFIG_DIR}/boards/${config}" ]; then
            config="${CONFIG_DIR}/boards/${config}"
        elif [ -f "${CONFIG_DIR}/boards/${config}.yaml" ]; then
            config="${CONFIG_DIR}/boards/${config}.yaml"
        else
            error_exit "Config file not found: ${config}"
        fi
    fi

    prepare_android_images "${config}" "${mode}" "${out_dir}" "${gen_sdcard}"
}

if [ "$0" = "$BASH_SOURCE" ]; then
    prepare_android_main "$@"
fi
