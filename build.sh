#!/usr/bin/env bash
set -euo pipefail

# ─── Variables ────────────────────────────────────────────────────────────────
OUT=out
LOG=build.log
ERRORLOG=errors.log
JOBS=$(nproc --all)
DEFCONFIG=rosemary_defconfig
KERNEL_IMAGE=out/arch/arm64/boot/Image.gz
ANYKERNEL_DIR=builds/AnyKernel3
ZIP_OUT="$(pwd)/builds"
TOOLCHAIN="/home/omrxdev/clang-r563880/bin"

# ─── Toolchain ────────────────────────────────────────────────────────────────
export ARCH=arm64
export SUBARCH=arm64
export CC="$TOOLCHAIN/clang"
export LD="$TOOLCHAIN/ld.lld"
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
ok()    { echo -e "${GREEN}[  OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

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

# Warn if system clang shadows toolchain clang
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
rm -rf "$OUT"
rm -f "$LOG" "$ERRORLOG"
touch "$LOG" "$ERRORLOG"

# ─── Configure ────────────────────────────────────────────────────────────────
log "Configuring with $DEFCONFIG..."
make O="$OUT" \
    CC="$TOOLCHAIN/clang" \
    LD="$TOOLCHAIN/ld.lld" \
    LLVM=1 LLVM_IAS=1 \
    "$DEFCONFIG"

# ─── Inject SUSFS configs ─────────────────────────────────────────────────────
log "Injecting SUSFS Kconfig options..."
SUSFS_CONFIGS=(
    "CONFIG_KSU_SUSFS=y"
    "CONFIG_KSU_SUSFS_SUS_PATH=y"
    "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
    "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y"
    "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
    "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
    "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
    "CONFIG_KSU_SUSFS_SUS_SU=y"
)

for cfg in "${SUSFS_CONFIGS[@]}"; do
    key="${cfg%=*}"
    sed -i "/^${key}[= ]/d" "$OUT/.config"
    sed -i "/# ${key} is not set/d" "$OUT/.config"
    echo "$cfg" >> "$OUT/.config"
done

# Sync dependencies after manual config edits
log "Running olddefconfig to resolve dependencies..."
make O="$OUT" \
    CC="$TOOLCHAIN/clang" \
    LD="$TOOLCHAIN/ld.lld" \
    LLVM=1 LLVM_IAS=1 \
    olddefconfig

# Verify critical config is present
if ! grep -q "^CONFIG_KSU_SUSFS_SUS_MOUNT=y" "$OUT/.config"; then
    error "CONFIG_KSU_SUSFS_SUS_MOUNT was not set — check your Kconfig dependency chain."
    exit 1
fi
ok "SUSFS configs verified."

# ─── Build ────────────────────────────────────────────────────────────────────
# Set zip name here so kernel version is available after configure
KVER=$(make O="$OUT" -s kernelversion 2>/dev/null || echo "unknown")
ZIP_NAME="kernel-${KVER}-$(date +%Y%m%d-%H%M).zip"

log "Building kernel ${KVER} with $JOBS jobs..."
START_TIME=$(date +%s)

time make O="$OUT" -j"$JOBS" \
    CC="$TOOLCHAIN/clang" \
    LD="$TOOLCHAIN/ld.lld" \
    AR="$TOOLCHAIN/llvm-ar" \
    NM="$TOOLCHAIN/llvm-nm" \
    OBJCOPY="$TOOLCHAIN/llvm-objcopy" \
    OBJDUMP="$TOOLCHAIN/llvm-objdump" \
    STRIP="$TOOLCHAIN/llvm-strip" \
    LLVM=1 LLVM_IAS=1 \
    2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

if [[ $BUILD_STATUS -ne 0 ]]; then
    grep -E "^.*error:|undefined symbol" "$LOG" > "$ERRORLOG" || true
    error "Build failed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    error "═══════════════════════ BUILD ERRORS ═══════════════════════"
    cat "$ERRORLOG"
    error "═════════════════════════════════════════════════════════════"
    exit 1
fi

ok "Build completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ─── Package ──────────────────────────────────────────────────────────────────
if [[ ! -f "$KERNEL_IMAGE" ]]; then
    error "Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

log "Packaging AnyKernel3 zip..."
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"

pushd "$ANYKERNEL_DIR" > /dev/null
zip -r9 "$ZIP_OUT/$ZIP_NAME" -- * -x '*.zip'
popd > /dev/null

ok "Done! Output: $ZIP_OUT/$ZIP_NAME"
sleep 1

ok "Clean leftovers"
rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image