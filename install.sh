#!/usr/bin/env bash
#
# Apply the xHCI DMA bounce patch to a kernel tree, and optionally build and
# install the result.
#
# The patch itself is applied by patch-dma-bounce.py, which refuses to write
# anything unless every anchor matches. This wrapper only locates the tree,
# checks the toolchain, and drives the build.
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SELF_DIR/patch-dma-bounce.py"

SRC=""
DO_BUILD=0
MODE="apply"
ASSUME_YES=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m==> ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

  --src DIR     Kernel source tree. Default: autodetected (see below).
  --check       Verify that the patch applies. Writes nothing.
  --revert      Restore the .orig-dma backups in the tree.
  --build       After patching, build and install the kernel.
  --yes         Do not ask for confirmation before building.
  -h, --help    This message.

Without --build, only the source tree is patched; you then build the kernel
the way you normally do. On the PS5 Ubuntu image that means running rmux's
build.sh, which is the only path this patch has been tested through.

Autodetection order for the source tree:
  1. $PWD, if it looks like a kernel tree
  2. SRC_DIR from ../ps5-linux-patches/build.cfg, if present
  3. ~/linux
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)     SRC="${2:-}"; shift 2 ;;
    --check)   MODE="check"; shift ;;
    --revert)  MODE="revert"; shift ;;
    --build)   DO_BUILD=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

[ -f "$PATCHER" ] || die "patch-dma-bounce.py not found next to this script"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ---------------------------------------------------------------- source tree
is_tree() { [ -f "$1/Makefile" ] && [ -d "$1/kernel/dma" ]; }

if [ -z "$SRC" ]; then
  if is_tree "$PWD"; then
    SRC="$PWD"
  else
    for cfg in "$SELF_DIR/../ps5-linux-patches/build.cfg" \
               "$HOME/ps5-linux-patches/build.cfg" \
               "$HOME/ps5-linux-patches-1/build.cfg"; do
      [ -f "$cfg" ] || continue
      cand="$(sed -n 's/^SRC_DIR=//p' "$cfg" | tr -d '"'"'"'' | head -1)"
      cand="${cand/#\~/$HOME}"
      [ -n "$cand" ] && is_tree "$cand" && { SRC="$cand"; break; }
    done
  fi
  [ -z "$SRC" ] && is_tree "$HOME/linux" && SRC="$HOME/linux"
fi

[ -n "$SRC" ] || die "no kernel source tree found. Pass --src /path/to/linux"
is_tree "$SRC" || die "$SRC does not look like a kernel source tree"
SRC="$(cd "$SRC" && pwd)"
say "kernel source: $SRC"

if [ -f "$SRC/.config" ]; then
  ver="$(sed -n '3s/^# Linux\/[^ ]* //p;3s/ Kernel Configuration$//p' "$SRC/.config" | head -1)"
  [ -n "$ver" ] && say "configured for: $ver"
fi

# ------------------------------------------------------------- revert / check
if [ "$MODE" = revert ]; then
  cd "$SRC" && exec python3 -I "$PATCHER" --revert
fi
if [ "$MODE" = check ]; then
  cd "$SRC" && exec python3 -I "$PATCHER" --check
fi

# ----------------------------------------------------------------- toolchain
missing=()
need=(make gcc bc cpio flex bison)
if [ -f "$SRC/.config" ] && grep -q '^CONFIG_CC_IS_CLANG=y' "$SRC/.config"; then
  need+=(clang ld.lld llvm-ar)
fi
for t in "${need[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if [ "${#missing[@]}" -gt 0 ]; then
  warn "missing tools: ${missing[*]}"
  warn "on Debian/Ubuntu:"
  warn "  sudo apt install build-essential git bc cpio libelf-dev clang lld llvm \\"
  warn "                   ccache initramfs-tools flex bison libssl-dev zstd kmod python3"
  [ "$DO_BUILD" = 1 ] && die "cannot build with tools missing"
fi

# --------------------------------------------------------------------- patch
say "applying the patch"
( cd "$SRC" && python3 -I "$PATCHER" )

if [ "$DO_BUILD" = 0 ]; then
  cat <<EOF

Source tree patched. Nothing was built.

Next step, if you use rmux's patch set (the tested path):

    cd ~/ps5-linux-patches && ./build.sh

Otherwise rerun this script with --build, or build the kernel your usual way.
To undo the source change:  ./install.sh --revert --src "$SRC"
EOF
  exit 0
fi

# --------------------------------------------------------------------- build
BUILDSH=""
for b in "$HOME/ps5-linux-patches/build.sh" "$HOME/ps5-linux-patches-1/build.sh"; do
  [ -x "$b" ] && { BUILDSH="$b"; break; }
done

if [ -n "$BUILDSH" ]; then
  say "found $BUILDSH -- this is the tested build path"
  say "it rebuilds with the same toolchain, LTO setting and -march as your"
  say "current kernel, installs the modules, regenerates the initrd and"
  say "deploys to the boot partition with a backup."
  if [ "$ASSUME_YES" = 0 ]; then
    read -r -p "==> run it now? [Y/n] " ans || die "no answer"
    case "$ans" in ""|y|Y) ;; *) say "stopping here; the source is patched"; exit 0 ;; esac
  fi
  exec "$BUILDSH"
fi

warn "rmux's build.sh was not found, falling back to a generic build."
warn "This path is UNTESTED. It uses the tree's existing .config."
if [ "$ASSUME_YES" = 0 ]; then
  read -r -p "==> continue with the generic build? [y/N] " ans || die "no answer"
  case "$ans" in y|Y) ;; *) die "stopped; the source is patched but nothing was built" ;; esac
fi

cd "$SRC"
MAKE_FLAGS=()
grep -q '^CONFIG_CC_IS_CLANG=y' .config 2>/dev/null && MAKE_FLAGS+=(LLVM=1)
LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' .config | head -1)"
[ -n "$LOCALVERSION" ] && MAKE_FLAGS+=(LOCALVERSION="$LOCALVERSION")

say "building with ${MAKE_FLAGS[*]:-no extra flags} on $(nproc) cores"
make -j"$(nproc)" "${MAKE_FLAGS[@]}"

KVER="$(make -s kernelrelease "${MAKE_FLAGS[@]}")"
say "built $KVER"

say "installing modules"
sudo make modules_install "${MAKE_FLAGS[@]}"

say "generating the initrd"
if command -v mkinitcpio >/dev/null 2>&1; then
  sudo mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER"
elif command -v update-initramfs >/dev/null 2>&1; then
  sudo update-initramfs -c -k "$KVER" || sudo update-initramfs -u -k "$KVER"
elif command -v dracut >/dev/null 2>&1; then
  sudo dracut --force "/boot/initrd.img-$KVER" "$KVER"
else
  die "no initramfs generator found (mkinitcpio, initramfs-tools or dracut)"
fi
[ -f "/boot/initrd.img-$KVER" ] || die "initrd was not created at /boot/initrd.img-$KVER"

# The PS5 image boots a raw bzImage + initrd.img from the EFI partition rather
# than through a boot loader, so deployment is a file copy. Find the mounted
# partition that already holds a bzImage and refuse to guess if there is none.
EFI_DIR=""
while read -r dev mnt _; do
  case "$dev" in /dev/*) ;; *) continue ;; esac
  mnt="$(printf '%b' "$mnt")"
  [ -f "$mnt/bzImage" ] && { EFI_DIR="$mnt"; break; }
done < /proc/mounts

if [ -z "$EFI_DIR" ]; then
  warn "no mounted partition with a bzImage found; not deploying."
  warn "kernel: arch/x86/boot/bzImage"
  warn "initrd: /boot/initrd.img-$KVER"
  exit 0
fi

say "deploying to $EFI_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p "$EFI_DIR/backup-$stamp"
sudo cp "$EFI_DIR/bzImage" "$EFI_DIR/backup-$stamp/" 2>/dev/null || true
sudo cp "$EFI_DIR/initrd.img" "$EFI_DIR/backup-$stamp/" 2>/dev/null || true
sudo cp arch/x86/boot/bzImage "$EFI_DIR/bzImage"
sudo cp "/boot/initrd.img-$KVER" "$EFI_DIR/initrd.img"
sudo sync
say "done. Previous files are in $EFI_DIR/backup-$stamp"
say "cold boot the PS5 to run the new kernel."
