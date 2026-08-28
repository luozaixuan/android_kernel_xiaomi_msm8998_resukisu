#!/bin/sh
# Update ReSukiSU to the latest main branch, rebuild and (optionally) repackage.
#
# Usage:
#   ./update-resukisu.sh [options]
#
# Options:
#   -y, --yes          Skip the confirmation when kernel/ changes are detected
#   -n, --no-build     Update and commit the submodule, but do not build
#   --no-commit        Do not commit the submodule pointer
#   -j, --jobs N       Build parallelism (default: nproc)
#   --ak3 DIR          Path to an AnyKernel3 template; if given, the new
#                      Image.gz-dtb is packaged into Chiron-ReSukiSU-...zip
#   -h, --help         Show this help
#
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SUBMODULE="$REPO_DIR/ReSukiSU"
ZIP_NAME="Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip"
MIN_VERSION=34634
LOG="$REPO_DIR/build-resukisu.log"

FORCE=0
NO_BUILD=0
NO_COMMIT=0
JOBS="$(nproc)"
AK3_DIR=""

usage() {
    sed -n '2,16p' "$0"
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) FORCE=1 ;;
        -n|--no-build) NO_BUILD=1 ;;
        --no-commit) NO_COMMIT=1 ;;
        -j|--jobs) shift; JOBS="$1" ;;
        --ak3) shift; AK3_DIR="$1" ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# 1. Prepare submodule
# ---------------------------------------------------------------------------
if ! git submodule status "$SUBMODULE" >/dev/null 2>&1; then
    echo "[1/6] initializing ReSukiSU submodule"
    git submodule update --init --recursive ReSukiSU
fi

if [ -n "$(git -C "$SUBMODULE" status --porcelain)" ]; then
    echo "ERROR: ReSukiSU submodule has local modifications; refusing to overwrite." >&2
    echo "       Stash/commit them first, then rerun." >&2
    exit 1
fi

OLD="$(git -C "$SUBMODULE" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 2. Fetch latest main
# ---------------------------------------------------------------------------
echo "[1/6] fetching ReSukiSU origin/main"
git -C "$SUBMODULE" fetch origin main
git -C "$SUBMODULE" checkout -q origin/main
NEW="$(git -C "$SUBMODULE" rev-parse HEAD)"

if [ "$OLD" = "$NEW" ]; then
    echo "Already up to date: $OLD"
    exit 0
fi

echo "OLD: $OLD"
echo "NEW: $NEW"

echo
echo "--- commits ---"
git -C "$SUBMODULE" log --oneline "$OLD..$NEW"
echo
echo "--- changed files ---"
git -C "$SUBMODULE" diff --stat "$OLD" "$NEW"

# ---------------------------------------------------------------------------
# 3. Warn about kernel/ changes
# ---------------------------------------------------------------------------
KERNEL_CHANGES="$(git -C "$SUBMODULE" diff --name-only "$OLD" "$NEW" -- kernel/ || true)"
if [ -n "$KERNEL_CHANGES" ]; then
    echo
    echo "WARNING: kernel/ changed. Manual integration may be required:"
    echo "$KERNEL_CHANGES" | sed 's/^/  /'
    echo "  - check kernel/tools/manual_hook_check.mk for new hook checks"
    echo "  - check kernel/Kconfig for new options"
    echo "  - docs: https://resukisu.github.io/guide/manual-integrate.html"
    if [ "$FORCE" -ne 1 ]; then
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 1 ;;
        esac
    fi
else
    echo
    echo "kernel/ unchanged: no source-level integration changes expected."
fi

# ---------------------------------------------------------------------------
# 4. Version code check
# ---------------------------------------------------------------------------
COUNT="$(git -C "$SUBMODULE" rev-list --count HEAD)"
VERSION="$((30000 + COUNT + 700))"
echo
echo "[2/6] ReSukiSU version code: $VERSION (commit count: $COUNT)"
if [ "$VERSION" -lt "$MIN_VERSION" ]; then
    echo "ERROR: version code below $MIN_VERSION. The submodule is probably a shallow clone." >&2
    echo "       Remove it and add it again without --depth." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Commit submodule pointer
# ---------------------------------------------------------------------------
if [ "$NO_COMMIT" -ne 1 ]; then
    git add ReSukiSU
    if ! git diff --cached --quiet; then
        DESCR="$(git -C "$SUBMODULE" describe --tags --always --dirty=-dirty)"
        git commit -m "ReSukiSU: update submodule to $DESCR"
        echo "[3/6] submodule pointer committed as $DESCR"
    else
        echo "[3/6] no submodule pointer change to commit"
    fi
else
    echo "[3/6] skipping commit (--no-commit)"
fi

# ---------------------------------------------------------------------------
# 6. Rebuild
# ---------------------------------------------------------------------------
if [ "$NO_BUILD" -eq 1 ]; then
    echo "[4/6] skipping build (--no-build)"
else
    echo "[4/6] cleaning previous build"
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    export CROSS_COMPILE_ARM32=arm-linux-gnueabihf-
    make O=out clean

    echo "[5/6] building kernel (-j$JOBS)"
    make O=out -j"$JOBS" Image.gz-dtb modules 2>&1 | tee "$LOG"
    grep -E 'ReSukiSU version code|ReSukiSU: using Manual Hook|manual_hook:' "$LOG" || true
fi

IMAGE="$REPO_DIR/out/arch/arm64/boot/Image.gz-dtb"
if [ -f "$IMAGE" ]; then
    echo
    echo "[6/6] build output:"
    ls -l "$IMAGE"
    sha256sum "$IMAGE"
else
    echo "WARNING: $IMAGE not found (build disabled or failed)" >&2
fi

# ---------------------------------------------------------------------------
# Optional AnyKernel3 packaging
# ---------------------------------------------------------------------------
if [ -n "$AK3_DIR" ]; then
    AK3_DIR="$(CDPATH= cd -- "$AK3_DIR" && pwd)"
    if [ ! -f "$AK3_DIR/anykernel.sh" ] || [ ! -f "$IMAGE" ]; then
        echo "ERROR: --ak3 dir must contain anykernel.sh, and Image.gz-dtb must exist." >&2
        exit 1
    fi
    echo
    echo "[package] copying kernel into AnyKernel3 template: $AK3_DIR"
    cp -f "$IMAGE" "$AK3_DIR/Image.gz-dtb"
    SHORT="$(git -C "$SUBMODULE" rev-parse --short=8 HEAD)"
    sed -i "s|^kernel.string=.*|kernel.string=Chiron-ReSukiSU ${SHORT} (${VERSION}) 4.4.302-perf-resukisu for LineageOS 22.2|" \
        "$AK3_DIR/anykernel.sh"
    python3 - "$AK3_DIR" "$REPO_DIR/$ZIP_NAME" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    os.remove(out)
zf = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d != ".git"]
    for f in files:
        fp = os.path.join(root, f)
        rel = os.path.relpath(fp, src)
        mode = (os.stat(fp).st_mode & 0o777) or 0o644
        zi = zipfile.ZipInfo(rel)
        zi.external_attr = (mode & 0xFFFF) << 16
        zi.create_system = 3
        with open(fp, "rb") as fh:
            zf.writestr(zi, fh.read())
zf.close()
print(out)
PY
    echo "[package] zip:"
    ls -l "$REPO_DIR/$ZIP_NAME"
    sha256sum "$REPO_DIR/$ZIP_NAME"
fi

echo
echo "Done. Flash with: adb reboot recovery && adb sideload $ZIP_NAME"
