#!/bin/sh
# Build ReSukiSU kernel for Xiaomi Mi MIX 2 (chiron) / LineageOS 22.2
# Requirements: gcc-aarch64-linux-gnu, gcc-arm-linux-gnueabihf, make, flex,
#               bison, bc, libssl-dev, libelf-dev, git (Ubuntu 24.04)
set -e

# ReSukiSU is a git submodule; make sure it is checked out.
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

echo
echo "Kernel: out/arch/arm64/boot/Image.gz-dtb"
