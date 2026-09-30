# bootloader/build-bootloaders: android16-riscv

Changes made for the Android 16 (AOSP, riscv64) bring-up of the BananaPi BPI-F3 (SpacemiT K1) and the BananaPi BPI-SM10 (SpacemiT K3), on branch `android16-riscv`.

Bootloader build scripts (OpenSBI + U-Boot) for the SpacemiT K1 boards.

## Changes

- **config: add a logo partition for the U-Boot splash screen**: pi-u-boot (android16-riscv) reads a raw BMP from the "logo" GPT partition; flash it with fastboot flash logo logo.bmp.
- **release_android: stage without commit bookkeeping unless --commit**: The AOSP build.sh (device/spacemit/common/build) builds the bootloaders from source into directories that are not git projects; the dry-run commit message step failed there.
- **Build the K1 boards with upstream OpenSBI and the RISE OP-TEE work**: opensbi.src picks the OpenSBI tree per board (default still pi-opensbi). spacemit-k1 and spacemit-musepi-pro now use ../opensbi (OpenSBI 1.8 + the RISE MPXY/RPMI TEE branch, K1 in the generic platform, generic defconfig), the base for OP-TEE on the K1.
- **Build OP-TEE OS for the K1 boards**: build_optee.sh builds ../optee_os (plat-spacemit) for boards with an optee section and stages tee.bin into pi-u-boot, whose u-boot.itb then loads it into the OpenSBI trusted domain. The riscv64 TA dev kit lands in out/<board>/<mode>/optee/export-ta_rv64.
- **Enable the OP-TEE client in the K1 Android U-Boot**: U-Boot hands the AVB root of trust to OP-TEE for KeyMint. The AVB TA is left out: its storage needs RPMB, so rollback indexes and the lock state stay U-Boot's own.
- **boards: add SpacemiT K3** (BayLibre): per-board `opensbi.src`/`uboot.src`, K3 factory blobs, `k3_android.config`, K3 SPI-NOR layout.
- **prebuilts: add the K3 RCPU firmware** (BayLibre): ESOS RT24 firmware and Pico-ITX dtbs packed into the K3 u-boot.itb.
- **Keep the K1 SPI-NOR layout next to the K3 one**: the K3 commit replaced partition_nor.json, which the MusePi Pro still flashes; the K3 layout is partition_nor_k3.json, picked with `android.partition_nor`.
- **spacemit-k3: build the K3 trees of this workspace**: bootloader/spacemit/k3-opensbi and k3-u-boot.
- **Pick the RISC-V toolchain per board**: `toolchain: spacemit` (GCC 15.2) for the K3; the K1 boards keep Bootlin GCC 12.
- **prebuilts: add the K3-CoM260 kit RCPU dtbs**: ESOS dtbs for the BPI-SM10 (`/model` k3_com260_kit_v02, rslpm disabled) from SpacemiT Buildroot K3 v1.0.0; every dtb of prebuilts/rcpu is staged.
- **boards: add the Banana Pi BPI-SM10**: bananapi-sm10.yaml + k3_bananapi_sm10.config (SM10 device tree, product name).

## Notes

- OP-TEE: boards with an `optee` section (spacemit-k1, spacemit-musepi-pro) build `../optee_os` (PLATFORM=spacemit-k1) before U-Boot; the riscv64 TA dev kit is in `out/<board>/<mode>/optee/export-ta_rv64`.
- In the Android tree this is `bootloader/spacemit/build-bootloaders` (local manifest `spacemit-sources.xml`), run by `build.sh`, which stages the release binaries into vendor/spacemit/{k1,musepi-pro}/bootloader.

## Build

```
./build.sh k1 --bootloader-only
```
