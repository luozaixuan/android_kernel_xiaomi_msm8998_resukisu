#!/bin/bash
# One-click packaging of the built chiron ReSukiSU kernel into an AnyKernel3 zip.
#
# Usage:
#   ./package-ak3.sh [options]
#
# Options:
#   -i, --image PATH      Kernel image to package
#                         (default: out/arch/arm64/boot/Image.gz-dtb)
#   -t, --template DIR    AnyKernel3 template directory (must contain anykernel.sh)
#   -d, --download        Clone the official AnyKernel3 template if needed
#   -o, --output PATH     Output zip path
#                         (default: Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip)
#   -D, --device NAME     Set device.name1 in anykernel.sh and name the output
#                         zip after the device (e.g. -D sagit -> Sagit-...zip)
#   --no-kernel-string    Do not rewrite kernel.string in anykernel.sh
#   -h, --help            Show this help
#
# Template resolution (first match wins):
#   1. --template DIR
#   2. existing Chiron-ReSukiSU-...zip in the repo (extracted automatically)
#   3. --download (official https://github.com/osm0sis/AnyKernel3)
set -euo pipefail

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SUBMODULE="$REPO_DIR/ReSukiSU"
IMAGE="$REPO_DIR/out/arch/arm64/boot/Image.gz-dtb"
TEMPLATE=""
DOWNLOAD=0
OUT=""
DEVICE=""
OUT_SPECIFIED=0
UPDATE_STRING=1
MIN_VERSION=34634

usage() { sed -n '2,22p' "$0"; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--image) shift; IMAGE="$1" ;;
        -t|--template) shift; TEMPLATE="$1" ;;
        -d|--download) DOWNLOAD=1 ;;
        -o|--output) shift; OUT="$1"; OUT_SPECIFIED=1 ;;
        -D|--device) shift; DEVICE="$1" ;;
        --no-kernel-string) UPDATE_STRING=0 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

if [ -z "$OUT" ]; then
    if [ -n "$DEVICE" ]; then
        CAP="$(printf '%s' "$DEVICE" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$DEVICE" | cut -c2-)"
        OUT="$REPO_DIR/${CAP}-ReSukiSU-Lineage22.2-AnyKernel3.zip"
    else
        OUT="$REPO_DIR/Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip"
    fi
fi
case "$OUT" in
    /*) ;;
    *) OUT="$REPO_DIR/$OUT" ;;
esac

# ---------------------------------------------------------------------------
# 1. Kernel image
# ---------------------------------------------------------------------------
if [ ! -f "$IMAGE" ]; then
    echo "ERROR: kernel image not found: $IMAGE" >&2
    echo "       Build it first with ./build-resukisu.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. AnyKernel3 template
# ---------------------------------------------------------------------------
if [ -n "$TEMPLATE" ]; then
    TEMPLATE="$(CDPATH= cd -- "$TEMPLATE" && pwd)"
    if [ ! -f "$TEMPLATE/anykernel.sh" ]; then
        echo "ERROR: $TEMPLATE is not an AnyKernel3 template (missing anykernel.sh)" >&2
        exit 1
    fi
    echo "[template] using: $TEMPLATE"
elif [ -f "$REPO_DIR/Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip" ]; then
    WORK="$(mktemp -d "$REPO_DIR/out/ak3-template.XXXXXX")"
    echo "[template] extracting existing zip as template: $WORK"
    python3 - "$REPO_DIR/Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip" "$WORK" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zf:
    for zi in zf.infolist():
        target = os.path.join(dst, zi.filename)
        if zi.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(zi) as fi, open(target, "wb") as fo:
            fo.write(fi.read())
        mode = (zi.external_attr >> 16) & 0o777
        if mode:
            os.chmod(target, mode)
PY
    TEMPLATE="$WORK"
elif [ "$DOWNLOAD" -eq 1 ]; then
    WORK="$(mktemp -d "$REPO_DIR/out/ak3-official.XXXXXX")"
    echo "[template] cloning official AnyKernel3: $WORK"
    git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$WORK"
    if [ -d "$WORK/AK3" ]; then
        TEMPLATE="$WORK/AK3"
    else
        TEMPLATE="$WORK"
    fi
else
    echo "ERROR: no AnyKernel3 template found." >&2
    echo "       Pass -t DIR, or -d to clone the official template." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. ReSukiSU version info (for kernel.string)
# ---------------------------------------------------------------------------
VERSION="unknown"
SHORT="unknown"
if git -C "$SUBMODULE" rev-parse --git-dir >/dev/null 2>&1; then
    COUNT="$(git -C "$SUBMODULE" rev-list --count HEAD)"
    VERSION="$((30000 + COUNT + 700))"
    SHORT="$(git -C "$SUBMODULE" rev-parse --short=8 HEAD)"
    echo "[version] ReSukiSU $SHORT, version code $VERSION (commit count: $COUNT)"
    if [ "$VERSION" -lt "$MIN_VERSION" ]; then
        echo "WARNING: version code below $MIN_VERSION. The submodule is probably a shallow clone." >&2
    fi
fi

# ---------------------------------------------------------------------------
# 4. Copy kernel + update kernel.string
# ---------------------------------------------------------------------------
echo "[package] copying $IMAGE -> $TEMPLATE/Image.gz-dtb"
cp -f "$IMAGE" "$TEMPLATE/Image.gz-dtb"

if [ "$UPDATE_STRING" -eq 1 ] && [ -f "$TEMPLATE/anykernel.sh" ]; then
    STRING="Chiron-ReSukiSU ${SHORT} (${VERSION}) 4.4.302-perf-resukisu for LineageOS 22.2"
    if [ -n "$DEVICE" ] && grep -q '^device.name1=' "$TEMPLATE/anykernel.sh"; then
        sed -i "s|^device.name1=.*|device.name1=${DEVICE}|" "$TEMPLATE/anykernel.sh"
        echo "[package] device.name1=$DEVICE"
    fi
    if grep -q '^kernel.string=' "$TEMPLATE/anykernel.sh"; then
        sed -i "s|^kernel.string=.*|kernel.string=${STRING}|" "$TEMPLATE/anykernel.sh"
        echo "[package] kernel.string=$STRING"
    else
        echo "WARNING: no 'kernel.string=' line in anykernel.sh; skipping." >&2
    fi
fi

# ---------------------------------------------------------------------------
# 5. Zip (Python, preserves 0755 exec bits)
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" "$OUT" <<'PY'
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

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
echo "[verify]"
python3 -m zipfile -t "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
echo
echo "Flash: adb reboot recovery && adb sideload $(basename "$OUT")"
