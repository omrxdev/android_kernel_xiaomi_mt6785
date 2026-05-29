#!/usr/bin/env bash
set -euo pipefail

# ─── Variables ────────────────────────────────────────────────────────────────
OUT=out
LOG=build.log
ERRORLOG=errors.log
ARCH=arm64
SUBARCH=arm64
JOBS=$(nproc --all)
DEFCONFIG=rosemary_defconfig
KERNEL_IMAGE=out/arch/arm64/boot/Image.gz
ANYKERNEL_DIR=builds/AnyKernel3
ZIP_OUT="$(pwd)/builds"
TOOLCHAIN="$HOME/toolchains/clang-r563880/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain)
      TOOLCHAIN="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOOLCHAIN" ]]; then
  echo "Error: --toolchain <path> is required" >&2
  exit 1
fi

# ─── Toolchain ────────────────────────────────────────────────────────────────
export ARCH SUBARCH
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export PATH="$TOOLCHAIN:$PATH"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${CYAN}[BUILD]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}====================\n By omrXdev\n====================${NC}\n"

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ ! -f "$TOOLCHAIN/clang" ]] && { error "Toolchain not found at $TOOLCHAIN/clang Please run with --toolchain to configure it, or set it manually in the build script."; exit 1; }
[[ ! -d "$ANYKERNEL_DIR"   ]] && { error "AnyKernel3 not found at $ANYKERNEL_DIR. creating..."; mkdir -p "$ANYKERNEL_DIR";  exit 1; }

log "Toolchain: $("$TOOLCHAIN/clang" --version | head -1)" | sleep 0.5

# ─── Clean ────────────────────────────────────────────────────────────────────
log "Cleaning previous build artifacts..."
rm -f "$LOG" "$ERRORLOG" | sleep 0.5

# ─── Configure ────────────────────────────────────────────────────────────────
log "Configuring with $DEFCONFIG..."
make O="$OUT" "$DEFCONFIG"

# ─── Build ────────────────────────────────────────────────────────────────────
KVER=$(make O="$OUT" -s kernelversion 2>/dev/null || echo "unknown")
ZIP_NAME="kernel-${KVER}-$(date +%Y%m%d-%H%M).zip"

log "Kernel Version: ${KVER}"
START_TIME=$(date +%s)

set +e
make O="$OUT" -j"$JOBS" 2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Result ───────────────────────────────────────────────────────────────────
if [[ "$BUILD_STATUS" -ne 0 ]]; then
    error "Build FAILED in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

    grep -A 2 -E \
        '(^[^:]+\.[chS]:[0-9]+:[0-9]+: error:|undefined (symbol|reference)|^ld\.lld: error:|^clang.*: error:)' \
        "$LOG" > "$ERRORLOG" || true

    [[ -s "$ERRORLOG" ]] && warn "Errors written to $ERRORLOG" \
                         || warn "No errors extracted — check $LOG manually."

    exit "$BUILD_STATUS"
fi

ok "Build completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ─── Package ──────────────────────────────────────────────────────────────────
[[ ! -f "$KERNEL_IMAGE" ]] && { error "Kernel image not found at $KERNEL_IMAGE"; exit 1; }

log "Packaging AnyKernel3 zip..."
rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"

pushd "$ANYKERNEL_DIR" > /dev/null
zip -r9 "$ZIP_OUT/$ZIP_NAME" -- * -x '*.zip'
popd > /dev/null

rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image

ok "Done! Output: $ZIP_OUT/$ZIP_NAME"
