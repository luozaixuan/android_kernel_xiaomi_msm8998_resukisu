# Android kernel for Xiaomi Mi MIX 2 (chiron) with ReSukiSU

LineageOS 22.2 (Android 15) kernel source, branch lineage-22.2, with
[ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) integrated via its manual
hooks for this 4.4 kernel.

## Repo layout

- `ReSukiSU/` - ReSukiSU git submodule
- `drivers/kernelsu` - relative symlink to `ReSukiSU/kernel`
- `arch/arm64/configs/resukisu.config` - ReSukiSU build config fragment
- `fs/susfs.c`, `include/linux/susfs.h`, `include/linux/susfs_def.h` - SusFS
  v2.2.0 kernel-side integration (from `susfs/susfs_patch_to_4.4.patch`)
- SusFS inline KSU hooks in `fs/exec.c`, `fs/open.c`, `fs/stat.c`,
  `fs/read_write.c`, `kernel/reboot.c`, `kernel/sys.c`,
  `drivers/input/input.c` (from `susfs/susfs_inline_hook_patches.sh`,
  manually fixed for this msm8998 4.4 tree)
- Hook mode: **SuSFS Inline Hook** (`CONFIG_KSU_SUSFS=y`)

## Build

```sh
# initialize the ReSukiSU submodule first
git submodule update --init --recursive

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabihf-

make O=out chiron_defconfig
scripts/kconfig/merge_config.sh -m -O out \
    arch/arm64/configs/chiron_defconfig \
    arch/arm64/configs/resukisu.config
make O=out olddefconfig
make O=out -j"$(nproc)" Image.gz-dtb modules
```

Or simply run `./build.sh`.

## One-click scripts

- `./update-resukisu.sh` - update ReSukiSU to latest `main`, commit, rebuild
  (and optionally repackage with `--ak3 DIR`)
- `./build-resukisu.sh` - one-click build of `out/arch/arm64/boot/Image.gz-dtb`
  (checks toolchains, generates config, verifies ReSukiSU manual hooks)
- `./package-ak3.sh` - one-click packaging of the built kernel into
  `Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip`
  (auto-extracts the existing zip as AnyKernel3 template, or use `-t DIR` /
  `-d` to clone the official template; use `-D sagit` for a device-name
  variant zip such as `Sagit-ReSukiSU-Lineage22.2-AnyKernel3.zip`)

Typical flow: `./update-resukisu.sh` -> `./build-resukisu.sh` -> `./package-ak3.sh`.

## Output

- Kernel image: `out/arch/arm64/boot/Image.gz-dtb`
- Kernel release: `4.4.302-perf-resukisu+`
- Flashable zip: `Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip`

## Flash (Mi MIX 2, LineageOS 22.2)

1. Put `Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip` on the device.
2. Reboot to recovery (`adb reboot recovery`, or hold Power + Volume Up).
3. `Apply update` -> select the zip, or sideload:
   ```sh
   adb sideload Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip
   ```
4. Reboot to system.
5. Install the ReSukiSU manager APK from the
   [ReSukiSU releases](https://github.com/ReSukiSU/ReSukiSU/releases).
   Kernel and manager versions must both be >= 34634 for full module/sepolicy
   compatibility.

The zip only replaces the boot image via AnyKernel3; it does not wipe data.

SusFS features (hide sus paths / mounts / kstat, spoof uname & cmdline,
open redirect, sus map, etc.) are configured from the ReSukiSU manager
(SuSFS tab).
