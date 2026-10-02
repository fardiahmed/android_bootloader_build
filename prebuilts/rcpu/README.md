# K3 RCPU (ESOS) prebuilt blobs

Payloads packed by binman into `u-boot.itb` (see
`u-boot/arch/riscv/dts/k3-pico-itx-u-boot.dtsi`) and started by the SPL
before OpenSBI, so a live RPMI agent answers the MPXY device-power probe.

Provenance: SpacemiT vendor SDK build output (2026-06-19),
`k3-buildroot-sdk/output/k3/images/`:

- `rt24_os0_rcpu.elf`, `rt24_os1_rcpu.elf` — ESOS (RT-Thread) firmware for
  RCPU core0/core1, copied verbatim.
- `k3_rt240_pico_itx.dtb`, `k3_rt241_pico_itx.dtb` — ESOS dtbs for the
  Pico-ITX board, extracted from the vendor `esos.itb` (images 19/20,
  lzo-decompressed): `dumpimage -T flat_dt -p 19 -o x.lzo esos.itb && lzop -d`.
  Their `/model` ("k3-pico-itx") must match the product name the SPL writes
  into the `rcpu-data-null` slot (TLV EEPROM).
- `k3_rt240_com260_kit_v02.dtb`, `k3_rt241_com260_kit_v02.dtb` — ESOS dtbs for the
  K3-CoM260 kit V02 carrier (Banana Pi BPI-SM10), `/model` "k3_com260_kit_v02", images
  13/14 of the `esos.itb` in SpacemiT's Buildroot-K3-v1.0.0-20260430110238 release
  (archive.spacemit.com/image/k3/version/buildroot/v1.0.0/), extracted the same way.
  That release predates the firmware ELFs above (SDK 2026-06-19).
- `rcpu-data-null.bin` — 64 zero bytes; placeholder for the product-name
  slot at 0x1_00F00000 (the SPL FIT hook overwrites it at load time).

To regenerate after a vendor SDK update, rebuild `esos` in the SDK and
repeat the copies/extraction above.

## Local patch: rslpm disabled

Both dtbs carry a local modification on top of the vendor extraction:

    fdtput -t s <dtb> /soc/rslpm@20 status disabled

The ESOS low-power manager (`spacemit,rslpm` -> `lpm_thread`,
Idle/LightSleep/DeepSleep) autonomously enters sleep ~30s after boot and
gates resources shared with the AP (hard AP freeze, mid-UART-character).
On the vendor stack the AP activity is booked through the RPMI HSM/clock
services, which holds the sleep refcounts; our port drives the AP harts
natively, so the ESOS believes the system is idle. Re-enable only once
the HSM/clock-over-RPMI port lands.
