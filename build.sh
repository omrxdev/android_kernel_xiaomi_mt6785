#!/usr/bin/env bash
set -euo pipefail

# ─── Toolchain ────────────────────────────────────────────────────────────────
export ARCH=arm64
export SUBARCH=arm64
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export PATH="/home/omrxdev/linux-x86/clang-r563880/bin:$PATH"

# ─── Variables ────────────────────────────────────────────────────────────────
OUT=out
LOG=build.log
ERRORLOG=errors.log
JOBS=$(nproc --all)
DEFCONFIG=rosemary_defconfig
KERNEL_IMAGE=out/arch/arm64/boot/Image.gz
ANYKERNEL_DIR=builds/AnyKernel3
ZIP_NAME=kernel-$(date +%Y%m%d-%H%M).zip

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

# ─── Sanity checks ────────────────────────────────────────────────────────────
if ! command -v clang &>/dev/null; then
    error "clang not found in PATH. Check your toolchain path."
    exit 1
fi

if [[ ! -d "$ANYKERNEL_DIR" ]]; then
    error "AnyKernel3 directory not found at $ANYKERNEL_DIR"
    exit 1
fi

# ─── Clean ────────────────────────────────────────────────────────────────────
log "Cleaning previous build..."
rm -rf "$OUT"
rm -f "$LOG" "$ERRORLOG"
touch "$LOG"

# ─── Configure ────────────────────────────────────────────────────────────────
log "Configuring with $DEFCONFIG..."
make O="$OUT" "$DEFCONFIG"

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
    # Remove any existing entry (=y, =n, or unset line) then append
    sed -i "/^${key}[= ]/d" "$OUT/.config"
    sed -i "/# ${key} is not set/d" "$OUT/.config"
    echo "$cfg" >> "$OUT/.config"
done

# Sync dependencies after manual config edits
log "Running olddefconfig to resolve dependencies..."
make O="$OUT" olddefconfig

# Verify critical config is present
if ! grep -q "^CONFIG_KSU_SUSFS_SUS_MOUNT=y" "$OUT/.config"; then
    error "CONFIG_KSU_SUSFS_SUS_MOUNT was not set — check your Kconfig dependency chain."
    exit 1
fi
ok "SUSFS configs verified."

# ─── Build ────────────────────────────────────────────────────────────────────
log "Building kernel with $JOBS jobs..."
START_TIME=$(date +%s)

# Monitor Build
tail -f android_xiaomi_kernel_mt6785/build.log |
 grep -Ei "error:" && echo "ERROR FOUND"

if ! time make O="$OUT" -j"$JOBS" 2>&1 | tee "$LOG"; then
    error "Build failed! Extracting errors..."
    grep -E "error:|undefined symbol" "$LOG" > "$ERRORLOG" || true
    echo ""
    error "═══════════════════════ BUILD ERRORS ═══════════════════════"
    cat "$ERRORLOG"
    error "═════════════════════════════════════════════════════════════"
    exit 1
fi

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ok "Build completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ─── Package ──────────────────────────────────────────────────────────────────
if [[ ! -f "$KERNEL_IMAGE" ]]; then
    error "Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

log "Packaging AnyKernel3 zip..."
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"

pushd "$ANYKERNEL_DIR" > /dev/null
zip -r9 "../$ZIP_NAME" -- * -x '*.zip'
popd > /dev/null

ok "Done! Output: builds/$ZIP_NAME"
