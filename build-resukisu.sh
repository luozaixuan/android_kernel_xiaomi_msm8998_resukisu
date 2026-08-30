#!/bin/bash
# One-click build of the chiron (Xiaomi Mi MIX 2) ReSukiSU kernel.
#
# Usage:
#   ./build-resukisu.sh [options]
#
# Options:
#   -j, --jobs N       Build parallelism (default: nproc)
#   -c, --clean        Run make O=out clean before building
#   -k, --keep-config  Reuse existing out/.config instead of regenerating it
#   -h, --help         Show this help
#
# Output:
#   out/arch/arm64/boot/Image.gz-dtb   built kernel image
#   build-resukisu.log                 full build log
#
# After building, run ./package-ak3.sh to create the flashable AnyKernel3 zip.
set -euo pipefail

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOG="$REPO_DIR/build-resukisu.log"
JOBS="$(nproc)"
CLEAN=0
KEEP_CONFIG=0

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j|--jobs) shift; JOBS="$1" ;;
        -c|--clean) CLEAN=1 ;;
        -k|--keep-config) KEEP_CONFIG=1 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# Preflight: required tools
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing required tool: $1" >&2
        echo "       Install with: sudo apt-get install -y build-essential git make flex bison bc" >&2
        echo "                     libssl-dev libelf-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf" >&2
        exit 1
    }
}
for t in aarch64-linux-gnu-gcc arm-linux-gnueabihf-gcc make bc bison flex git python3; do
    need "$t"
done

echo "[prep] ReSukiSU submodule"
git submodule update --init --recursive ReSukiSU

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabihf-

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
    echo "[config] cleaning out/"
    make O=out clean
fi

if [ "$KEEP_CONFIG" -eq 1 ] && [ -f out/.config ]; then
    echo "[config] reusing existing out/.config (-k)"
else
    echo "[config] generating config: chiron_defconfig + resukisu.config"
    make O=out chiron_defconfig
    scripts/kconfig/merge_config.sh -m -O out \
        arch/arm64/configs/chiron_defconfig \
        arch/arm64/configs/resukisu.config
    make O=out olddefconfig
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "[build] make O=out -j$JOBS Image.gz-dtb modules (log: build-resukisu.log)"
make O=out -j"$JOBS" Image.gz-dtb modules 2>&1 | tee "$LOG"

# ---------------------------------------------------------------------------
# Verify ReSukiSU was built with all manual hooks
# ---------------------------------------------------------------------------
if grep -qE 'ReSukiSU version code|ReSukiSU: using Manual Hook|manual_hook:' "$LOG"; then
    echo
    echo "[verify] ReSukiSU build info:"
    grep -E 'ReSukiSU version code|ReSukiSU: using Manual Hook|manual_hook:' "$LOG" | sort -u
else
    echo "WARNING: ReSukiSU version/hook lines not found in log" >&2
fi

IMAGE="$REPO_DIR/out/arch/arm64/boot/Image.gz-dtb"
if [ -f "$IMAGE" ]; then
    echo
    echo "[done] kernel image:"
    ls -l "$IMAGE"
    sha256sum "$IMAGE"
    echo
    echo "Next: ./package-ak3.sh"
else
    echo "ERROR: $IMAGE not found; build failed (see build-resukisu.log)" >&2
    exit 1
fi
