#!/usr/bin/env bash
#
# Reproduce (or fail to reproduce) the PS5 Linux USB storage freeze.
#
# Writes a single 512 MB file over and over with direct I/O, and after each
# pass reports the machine-check count and whether the root filesystem is still
# writable. One file, rewritten in place, removed at the end: it never uses
# more than 512 MB of space.
#
# On an unpatched kernel this typically dies within a minute, and the machine
# freezes with it -- so do not run it on a console you need right now.
#
set -uo pipefail

ITERS="${1:-40}"
TARGET="${TARGET:-$HOME/.dma-repro.bin}"
STOP=/tmp/stop_repro

rm -f "$STOP"
echo "kernel: $(uname -r)"
if [ -r /sys/module/xhci_pci/parameters/force_dma_bounce ]; then
  echo "force_dma_bounce: $(cat /sys/module/xhci_pci/parameters/force_dma_bounce)"
else
  echo "force_dma_bounce: parameter absent (kernel not patched)"
fi
echo "target: $TARGET   iterations: $ITERS   stop early: touch $STOP"
echo

mce0=$(dmesg 2>/dev/null | grep -c "Hardware Error" || true)
echo "machine checks already in the log: $mce0"
echo

i=0
while [ "$i" -lt "$ITERS" ]; do
  if [ -e "$STOP" ]; then echo "stop requested"; break; fi

  if ! dd if=/dev/zero of="$TARGET" bs=1M count=512 \
         oflag=direct conv=fsync status=none 2>/dev/null; then
    echo "FAILED at iteration $i -- write error. This is the bug."
    break
  fi
  dd if="$TARGET" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null

  mce=$(dmesg 2>/dev/null | grep -c "Hardware Error" || true)
  rw=$(findmnt -no OPTIONS / | cut -d, -f1)
  printf 'iter %3d  mce=%-4s rootfs=%-3s %s\n' "$i" "$mce" "$rw" "$(date +%H:%M:%S)"

  if [ "$mce" != "$mce0" ]; then
    echo
    echo "NEW MACHINE CHECK -- the Data Fabric refused a DMA write:"
    dmesg | grep -A1 "Hardware Error" | tail -8
    break
  fi
  i=$((i + 1))
done

rm -f "$TARGET" "$STOP"
echo
echo "completed $i / $ITERS iterations"
echo "machine checks now: $(dmesg 2>/dev/null | grep -c 'Hardware Error' || true)"
echo "root filesystem: $(findmnt -no SOURCE,OPTIONS / 2>/dev/null)"
