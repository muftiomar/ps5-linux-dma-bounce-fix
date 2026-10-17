#!/usr/bin/env python3
"""Confine xHCI controller DMA to the swiotlb buffer.

Run from the root of a Linux source tree:

    python3 patch-dma-bounce.py --check    # verify the anchors, write nothing
    python3 patch-dma-bounce.py            # apply
    python3 patch-dma-bounce.py --revert   # restore the .orig-dma backups

WHY
    On the PS5, the Data Fabric refuses device DMA writes to some pages that
    the boot loader still reports as usable System RAM in the e820 map. The
    refusal is reported as a Coherent Station machine check (SMCA HWID 0x2E,
    MCAType 0x2, extended error code 0x02) with EN=0 and PCC=0: no exception
    is raised and the CPU is untouched, so nothing cancels the transfer. The
    xHCI controller then waits forever for a completion that never arrives,
    and roughly 14 seconds later the stack unwinds as

        uas_eh_abort_handler -> xHCI host not responding to stop endpoint
        command -> HC died -> USB disconnect -> rootfs read-only -> freeze

    Setting swiotlb=force on the kernel command line avoids the bad pages and
    makes the freeze disappear, but it applies to every device, and amdgpu does
    not survive it: the GPU asks for single 2 MB mappings while swiotlb caps a
    mapping at IO_TLB_SEGSIZE * 2 KB = 256 KB. The display never comes up.

    This patch makes the bounce selective. Only xHCI controllers are redirected,
    and only their *streaming* mappings -- coherent allocations (the xHCI rings
    and contexts) are left alone, which is correct because the failure happens
    on data transfers, not on ring memory. USB block I/O is already split into
    segments of at most 64 KB (max_segment_size), comfortably below the 256 KB
    per-mapping limit, which is why the USB path tolerates what the GPU cannot.

SAFETY
    The flag is honoured only when a swiotlb buffer actually exists
    (mem->nslabs non-zero). A kernel built without one degrades to the previous
    behaviour instead of failing every mapping, which would leave the machine
    unable to reach its root filesystem.

    Nothing is written unless every anchor matches exactly the expected number
    of times. If the kernel source has moved on, the script says so and exits
    without touching a single file.
"""
import os
import re
import sys

DEVICE_H = os.path.join("include", "linux", "device.h")
SWIOTLB_H = os.path.join("include", "linux", "swiotlb.h")
XHCI_PCI_C = os.path.join("drivers", "usb", "host", "xhci-pci.c")

SWIOTLB_OLD = re.compile(
    r"static inline bool is_swiotlb_force_bounce\(struct device \*dev\)\n\{\n"
    r"\tstruct io_tlb_mem \*mem = dev->dma_io_tlb_mem;\n\n"
    r"\treturn mem && mem->force_bounce;\n\}"
)

COMMENT = """\
\tif (!mem)
\t\treturn false;

\t/*
\t * A device may ask for its streaming mappings to be bounced even when
\t * bouncing is not forced globally. On the PS5 the Data Fabric rejects
\t * device writes to some pages that the e820 map still reports as
\t * usable; the rejection raises no exception, so the controller waits
\t * forever for a completion that never comes. Keeping the transfers
\t * inside the swiotlb buffer stays clear of those pages.
\t *
\t * Honour the flag only when a buffer actually exists, so that a
\t * kernel built without one degrades to the old behaviour instead of
\t * failing every mapping.
\t */
"""

PARAM_BLOCK = """\
static bool force_dma_bounce = true;
module_param(force_dma_bounce, bool, 0444);
MODULE_PARM_DESC(force_dma_bounce,
\t\t "Confine controller DMA to the swiotlb buffer (PS5: the Data "
\t\t "Fabric rejects device writes to some pages the e820 map still "
\t\t "reports as usable, which wedges the controller). Default on.");
"""


def fail(msg):
    sys.exit("ERROR: %s\nNothing was written." % msg)


def read(path):
    if not os.path.isfile(path):
        fail("%s not found. Run this from the root of a kernel source tree." % path)
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def sub_once(text, pattern, repl, what, path):
    out, n = pattern.subn(repl, text, count=1)
    if n != 1:
        total = len(pattern.findall(text))
        fail("%s: anchor for %r matched %d times, expected 1. "
             "This kernel version is not supported by this script; patch it by "
             "hand or open an issue with your kernel version."
             % (path, what, total))
    return out


def patch_device_h_flags(src):
    """Kernels using the DEV_FLAG_* bitmap (7.x and later)."""
    nums = [int(m) for m in re.findall(r"\tDEV_FLAG_[A-Z_0-9]+ = (\d+),\n", src)]
    if not nums:
        fail("%s: could not read the DEV_FLAG_* numbering." % DEVICE_H)
    nxt = max(nums) + 1

    src = sub_once(
        src,
        re.compile(r"(\n \* @DEV_FLAG_COUNT: Number of defined struct_device_flags\.)"),
        "\n * @DEV_FLAG_DMA_FORCE_BOUNCE: Confine this device's streaming DMA to the\n"
        " *\t\tswiotlb buffer. Used on PS5, where the Data Fabric rejects device\n"
        " *\t\twrites to some pages the firmware keeps for itself.\\1",
        "DEV_FLAG_DMA_FORCE_BOUNCE documentation", DEVICE_H)

    src = sub_once(
        src,
        re.compile(r"(\n\n\tDEV_FLAG_COUNT\n)"),
        "\n\tDEV_FLAG_DMA_FORCE_BOUNCE = %d,\\1" % nxt,
        "DEV_FLAG_DMA_FORCE_BOUNCE enumerator", DEVICE_H)

    src = sub_once(
        src,
        re.compile(r"(__create_dev_flag_accessors\(dma_skip_sync, "
                   r"DEV_FLAG_DMA_SKIP_SYNC\);\n)"),
        "\\1__create_dev_flag_accessors(dma_force_bounce, "
        "DEV_FLAG_DMA_FORCE_BOUNCE);\n",
        "dma_force_bounce accessors", DEVICE_H)
    return src


def patch_device_h_bitfield(src):
    """Kernels where struct device still carries plain bool bitfields (6.x).

    UNTESTED. Reported here so the failure is loud rather than silent.
    """
    return sub_once(
        src,
        re.compile(r"(\n\tstruct io_tlb_mem \*dma_io_tlb_mem;\n)"),
        "\n\tbool\t\t\tdma_force_bounce:1;\\1",
        "dma_force_bounce bitfield", DEVICE_H)


def main():
    check = "--check" in sys.argv
    revert = "--revert" in sys.argv

    if not os.path.isfile("Makefile") or not os.path.isdir("kernel/dma"):
        fail("this does not look like a kernel source tree "
             "(no Makefile, no kernel/dma)")

    targets = [DEVICE_H, SWIOTLB_H, XHCI_PCI_C]

    if revert:
        restored = 0
        for path in targets:
            bak = path + ".orig-dma"
            if os.path.isfile(bak):
                os.replace(bak, path)
                print("  restored %s" % path)
                restored += 1
        if not restored:
            print("No .orig-dma backup found; nothing to revert.")
        else:
            print("\nReverted %d file(s). Rebuild the kernel to go back." % restored)
        return 0

    device_src = read(DEVICE_H)
    swiotlb_src = read(SWIOTLB_H)
    xhci_src = read(XHCI_PCI_C)

    if "dma_force_bounce" in device_src and "force_dma_bounce" in xhci_src:
        print("Already patched; nothing to do.")
        return 0

    # Which flavour of struct device is this?
    if "__create_dev_flag_accessors" in device_src:
        flavour = "DEV_FLAG bitmap (6.17+/7.x)"
        device_out = patch_device_h_flags(device_src)
        read_flag = "dev_dma_force_bounce(dev)"
        set_flag = "dev_set_dma_force_bounce(&dev->dev);"
    else:
        flavour = "bool bitfield (6.x) -- UNTESTED"
        device_out = patch_device_h_bitfield(device_src)
        read_flag = "dev->dma_force_bounce"
        set_flag = "dev->dev.dma_force_bounce = true;"
    print("  struct device flavour: %s" % flavour)

    if not SWIOTLB_OLD.search(swiotlb_src):
        fail("%s: is_swiotlb_force_bounce() does not look the way this script "
             "expects. Your kernel is either too old (no per-device swiotlb, "
             "pre-5.19) or has changed. Patch it by hand." % SWIOTLB_H)

    swiotlb_out = SWIOTLB_OLD.sub(
        "static inline bool is_swiotlb_force_bounce(struct device *dev)\n"
        "{\n"
        "\tstruct io_tlb_mem *mem = dev->dma_io_tlb_mem;\n\n"
        + COMMENT +
        "\tif (%s && mem->nslabs)\n"
        "\t\treturn true;\n\n"
        "\treturn mem->force_bounce;\n}" % read_flag,
        swiotlb_src, count=1)
    print("  ok  %s: is_swiotlb_force_bounce() honours the per-device request"
          % SWIOTLB_H)

    xhci_out = sub_once(
        xhci_src,
        re.compile(r"(\nstatic int xhci_pci_probe\(struct pci_dev \*dev, "
                   r"const struct pci_device_id \*id\)\n\{\n)"),
        "\n" + PARAM_BLOCK + "\\1",
        "force_dma_bounce module parameter", XHCI_PCI_C)

    xhci_out = sub_once(
        xhci_out,
        re.compile(r"(\n\treturn xhci_pci_common_probe\(dev, id\);\n\}\n)"),
        "\n\tif (force_dma_bounce)\n\t\t%s\n\\1" % set_flag,
        "flag assignment in xhci_pci_probe()", XHCI_PCI_C)
    print("  ok  %s: flag set at probe, before any mapping" % XHCI_PCI_C)

    # Post-conditions: refuse to write a tree that would not build as intended.
    checks = [
        (device_out, "dma_force_bounce", 1, DEVICE_H),
        (swiotlb_out, "mem->nslabs", 1, SWIOTLB_H),
        (xhci_out, "force_dma_bounce", 4, XHCI_PCI_C),
    ]
    for text, needle, minimum, path in checks:
        if text.count(needle) < minimum:
            fail("post-check failed on %s (%r appears %d time(s), expected at "
                 "least %d)" % (path, needle, text.count(needle), minimum))
    print("  ok  post-checks")

    if check:
        print("\n--check: all anchors match. Nothing was written.")
        return 0

    for path, text, original in ((DEVICE_H, device_out, device_src),
                                 (SWIOTLB_H, swiotlb_out, swiotlb_src),
                                 (XHCI_PCI_C, xhci_out, xhci_src)):
        bak = path + ".orig-dma"
        if not os.path.exists(bak):
            with open(bak, "w", encoding="utf-8") as fh:
                fh.write(original)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("patched %s  (backup %s)" % (path, bak))

    print("\nNow rebuild and install the kernel. On the PS5 image that means "
          "running rmux's build.sh; see the README.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
