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
TOOLCHAIN="/home/omrxdev/toolchains/clang-r563880/bin"
TOOLCHAIN_NAME=clang

# ─── Toolchain ────────────────────────────────────────────────────────────────
export ARCH="$ARCH"
export SUBARCH="$SUBARCH"
export CC="$TOOLCHAIN_NAME"
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

# ─── Error Extraction ─────────────────────────────────────────────────────────
extract_errors() {
    local logfile="$1"
    local outfile="$2"

    # Clear previous error log
    > "$outfile"

    # Kernel build errors: file:line:col: error: message
    grep -E "^[^:]+\.[chS]:[0-9]+:[0-9]+: error:" "$logfile" >> "$outfile" || true

    # Linker errors: undefined symbol / undefined reference
    grep -E "undefined (symbol|reference)" "$logfile" >> "$outfile" || true

    # Kbuild errors: make[N]: *** [...] Error N
    grep -E "^\s*make(\[[0-9]+\])?: \*\*\*" "$logfile" >> "$outfile" || true

    # ld.lld fatal errors
    grep -E "^ld\.lld: error:" "$logfile" >> "$outfile" || true

    # clang fatal errors (not build errors, e.g. missing headers)
    grep -E "^clang.*: error:" "$logfile" >> "$outfile" || true

    # Deduplicate while preserving order
    sort -u "$outfile" -o "$outfile"

    local count
    count=$(wc -l < "$outfile")
    echo "$count"
}

# ─── Trap Cleanup ─────────────────────────────────────────────────────────────
trap 'error "Build interrupted!"; exit 130' INT TERM
trap 'error "Unexpected error on line $LINENO"' ERR

# ─── Beginning ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}====================\n By omrXdev\n====================${NC}\n"

# ─── Sanity checks ────────────────────────────────────────────────────────────
if [[ ! -f "$TOOLCHAIN/clang" ]]; then
    error "Toolchain clang not found at $TOOLCHAIN/clang"
    exit 1
fi

RESOLVED=$(command -v clang 2>/dev/null || true)
if [[ "$RESOLVED" != "$TOOLCHAIN/clang" ]]; then
    warn "System clang detected at $RESOLVED — toolchain will be used explicitly."
fi

if [[ ! -d "$ANYKERNEL_DIR" ]]; then
    error "AnyKernel3 directory not found at $ANYKERNEL_DIR"
    exit 1
fi

log "Toolchain: $("$TOOLCHAIN/clang" --version | head -1)"
sleep 1

# ─── Clean ────────────────────────────────────────────────────────────────────
log "Cleaning previous build..."
rm -f "$LOG" "$ERRORLOG"
touch "$LOG" "$ERRORLOG"

# ─── Configure ────────────────────────────────────────────────────────────────
log "Configuring with $DEFCONFIG..."
make O="$OUT" "$DEFCONFIG"

# Sync dependencies
log "Running olddefconfig to resolve dependencies..."
make O="$OUT" olddefconfig

# ─── Build ────────────────────────────────────────────────────────────────────
KVER=$(make O="$OUT" -s kernelversion 2>/dev/null || echo "unknown")
ZIP_NAME="kernel-${KVER}-$(date +%Y%m%d-%H%M).zip"

log "Building kernel ${KVER} with $JOBS jobs..."
START_TIME=$(date +%s)

# Monitor Build
log "Starting Build Monitor"
sleep 1
kitty sh -c "tail -f "$LOG" | grep -E "error:" && echo "Error Found" | tee "$ERRORLOG"; exec bash" 2>/dev/null &
sleep 1

time make O="$OUT" -j"$JOBS" 2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

ok "Build completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ─── Package ──────────────────────────────────────────────────────────────────
if [[ ! -f "$KERNEL_IMAGE" ]]; then
    error "Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

log "Packaging AnyKernel3 zip..."
rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"

pushd "$ANYKERNEL_DIR" > /dev/null
zip -r9 "$ZIP_OUT/$ZIP_NAME" -- * -x '*.zip'
popd > /dev/null

ok "Done! Output: $ZIP_OUT/$ZIP_NAME"
sleep 1

log "Cleaning leftovers\n"
rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image

ok "Done. Leaving now"
sleep 1
