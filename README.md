# ps5-linux-dma-bounce-fix

A kernel patch for the PS5 Linux freeze that happens when you write to USB
storage — the one where the drive disconnects mid-download and the whole
machine locks up until you reboot.

The patch confines xHCI controller DMA to the swiotlb bounce buffer, which
keeps transfers away from the pages that cause the hang. It is three files and
about twenty lines.

## The symptom

You are downloading something, or copying a large file, onto the USB drive you
booted Linux from. After anywhere between one minute and an hour:

```
sd 1:0:0:0: [sda] tag#9 uas_eh_abort_handler 0 uas-tag 10 inflight: CMD OUT
sd 1:0:0:0: [sda] tag#9 CDB: Write(10) 2a 00 ...
xhci_hcd 0000:20:00.5: xHCI host not responding to stop endpoint command
xhci_hcd 0000:20:00.5: xHCI host controller not responding, assume dead
xhci_hcd 0000:20:00.5: HC died; cleaning up
usb 4-1: USB disconnect, device number 2
sd 1:0:0:0: Device offlined - not ready after error recovery
EXT4-fs error: Aborting journal on device sda1-8
```

The root filesystem goes read-only, SSH stops accepting connections, and the
screen freezes. Keyboard and mouse often still work, because they are on a
different controller — which is the first hint that the USB stack is not the
culprit.

## What is actually wrong

The xHCI controller is a **victim**, not the cause. Nine to fourteen seconds
*before* it gives up, the platform has already logged this:

```
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 45: dc2030000002085b
mce: [Hardware Error]: TSC 0 ADDR 2ad0d00 MISC d01a000400000000 SYND 5b260028 IPID 2002e0000000d
```

`IPID 0x0002002e_0000000d` decodes to HWID `0x2E` / MCAType `0x2`, which the
kernel's SMCA tables name **Coherent Station** — a block of the AMD Data
Fabric. The extended error code is `0x02`. In short: **the Data Fabric refused
a DMA write from the USB controller.**

Two details explain why a refused write freezes the machine instead of
producing a clean error:

| bit | name | value | consequence |
|----:|------|-------|-------------|
| 60 | `EN` | 0 | this bank raises no `#MC` exception |
| 57 | `PCC` | 0 | the CPU context is intact |
| 44 | `DEFERRED` | 1 | the error is merely recorded |

Nothing aborts the transfer. Linux writes a line to the log and carries on,
while the controller waits for a completion that will never arrive. The USB
timeout machinery eventually declares the host dead, and the root filesystem
goes with it.

The refused addresses are the giveaway. Every failure reports sixteen MCE banks
covering **one single 4 KiB page**, sliced into 256-byte chunks interleaved
across the sixteen Coherent Station instances:

```
failure 1:  ADDR 1be50000, 1be50100, 1be50200 ... 1be50f00
failure 2:  ADDR 02ad0000, 02ad0100, 02ad0200 ... 02ad0f00
```

Both pages are declared `System RAM` by the e820 map, so Linux is entitled to
use them — and both sit below the first gigabyte. The page differs from one
failure to the next, so this is not one contiguous forbidden region but pages
scattered through low memory that the firmware keeps for itself and the boot
loader fails to mark reserved.

**The real upstream fix therefore belongs in the loader's memory map, not in
Linux.** This patch is a safety net that works today and does not depend on
anyone releasing the loader source.

See [docs/DIAGNOSIS.md](docs/DIAGNOSIS.md) for the full evidence, including the
eight hypotheses that were measured and ruled out first.

## Status — read this before you use it

| | Tested |
|---|---|
| Image | `ps5-ubuntu2604.img.xz` (Ubuntu 26.04.1 LTS, *resolute*) |
| Kernel patch set | [rmuxnet/ps5-linux-patches-1](https://github.com/rmuxnet/ps5-linux-patches-1) |
| Kernel | `7.3.0-rc7-PinkSoup`, clang FullLTO |
| Console | PS5 *fat* |
| Storage | NVMe in a HIKSEMI enclosure (RTL9210, `0bda:9210`), USB-C front port, UAS |
| Controller | AMD Ariel USB 3.1 Type C `1022:13ed` at `0000:20:00.5` |

**It has not been tested anywhere else.** Not on a Slim, not on a Pro, not with
another distribution, not with another kernel branch, not with the drive on a
rear USB-A port.

**Validation so far is synthetic load, not a long run.** What was measured:

| Kernel | Load survived | `Hardware Error` lines | Display |
|---|---|---|---|
| unmodified | **failed in under a minute**, twice out of twice | 64 each time | works |
| `swiotlb=force` on the command line | 140 GB | 0 | **dead** |
| this patch | 25 GB written + 20 GB read | 0 | works |

Throughput with the patch: 648–728 MB/s, i.e. unchanged.

A multi-hour real download has **not** been confirmed yet. If you run one,
please open an issue either way — a negative result is just as useful.

## Why not just `swiotlb=force`?

Because it works and then takes your display with it. `swiotlb=force` applies
to every device, and amdgpu asks for single 2 MB mappings while swiotlb caps a
mapping at `IO_TLB_SEGSIZE * 2 KB = 256 KB`:

```
amdgpu 0000:20:00.0: swiotlb buffer is full (sz: 2097152 bytes), total 32768 (slots), used 33 (slots)
```

No DRM card is registered, `/sys/class/drm/` holds only `version`, and the
screen stays black. USB block I/O, by contrast, is already split into segments
of at most 64 KB (`max_segment_size`), comfortably below the limit — which is
exactly why the USB path tolerates what the GPU cannot.

That said, if you just want tonight's download to finish and you do not need
the screen, `swiotlb=force` on the kernel command line is one line and needs no
build.

## What you need

On Arch, rmux's README asks for:

```sh
sudo pacman -S --needed base-devel git bc cpio libelf clang lld llvm ccache mkinitcpio
```

The Debian/Ubuntu equivalent is:

```sh
sudo apt install build-essential git bc cpio libelf-dev clang lld llvm \
                 ccache initramfs-tools flex bison libssl-dev zstd kmod python3
```

Mapping, package by package:

| Arch | Debian / Ubuntu | note |
|---|---|---|
| `base-devel` | `build-essential` | Arch's group also pulls in `flex` and `bison`; apt does not, hence the two extra entries |
| `libelf` | `libelf-dev` | headers are a separate package on Debian |
| `mkinitcpio` | `initramfs-tools` | different generator, same job — `install.sh` handles `mkinitcpio`, `update-initramfs` and `dracut` |
| — | `libssl-dev` | needed to build the kernel's certificate tooling; on Arch openssl headers come with the base system |
| `bc` `cpio` `clang` `lld` `llvm` `ccache` | same names | |

Add `dwarves` if your config has `CONFIG_DEBUG_INFO_BTF=y`, and
`libncurses-dev` if you want `make menuconfig`. On the
`ps5-ubuntu2604.img.xz` image all of these are already installed.

## Usage

```sh
git clone https://github.com/muftiomar/ps5-linux-dma-bounce-fix
cd ps5-linux-dma-bounce-fix

./install.sh --check          # verify the patch applies, write nothing
./install.sh                  # patch the source tree only
./install.sh --build          # patch, then build and install
./install.sh --revert         # restore the original files
```

The kernel tree is autodetected: the current directory if it is one, otherwise
`SRC_DIR` from a neighbouring `ps5-linux-patches/build.cfg`, otherwise
`~/linux`. Override with `--src /path/to/linux`.

With `--build`, if rmux's `build.sh` is present it is used, because that is the
only build path this patch has been validated through: it reuses your current
toolchain, LTO setting and `-march`, installs the modules, regenerates the
initrd and deploys to the boot partition with a backup. Without it, a generic
build runs instead — that path is **untested**, and the script says so before
starting.

Then cold boot the PS5. Rebooting from inside Linux returns you to the PS5
firmware, so you have to redo the jailbreak and reload the loader.

### Checking that it took effect

```sh
cat /sys/module/xhci_pci/parameters/force_dma_bounce   # expect: Y
ls /sys/class/drm/                                     # expect a card0, i.e. the GPU still works
dmesg | grep -c "Hardware Error"                       # expect: 0 after a heavy write
```

### Turning it off without rebuilding

Add this to the kernel command line:

```
xhci_pci.force_dma_bounce=0
```

## What the patch does

Three files, and nothing else:

- **`include/linux/device.h`** — adds a `DEV_FLAG_DMA_FORCE_BOUNCE` device flag.
- **`include/linux/swiotlb.h`** — `is_swiotlb_force_bounce()` honours that flag,
  *but only when a swiotlb buffer actually exists* (`mem->nslabs` non-zero). A
  kernel built without one degrades to the previous behaviour rather than
  failing every mapping, which would leave the machine unable to reach its root
  filesystem.
- **`drivers/usb/host/xhci-pci.c`** — sets the flag at `probe`, before any
  mapping is made, behind a `force_dma_bounce` module parameter that defaults
  to on.

Only **streaming** mappings are redirected. Coherent allocations — the xHCI
rings and device contexts — are untouched, which is correct: the failure
happens on data transfers, not on ring memory, and those rings have always
worked.

`patch-dma-bounce.py` does the editing with anchored regular expressions and
refuses to write anything unless every anchor matches exactly once. If your
kernel has moved on, it tells you and exits without touching a file. It also
detects which flavour of `struct device` you have: the `DEV_FLAG_*` bitmap used
by 6.17 and later, or the older plain `bool` bitfields — the latter path is
**untested**, and the script labels it as such when it takes it.

Requires a kernel with per-device swiotlb support, i.e. 5.19 or later.

## Risks and limitations

- **Bounce buffer exhaustion.** Under extreme concurrent USB I/O you could see
  `swiotlb buffer is full`, which surfaces as an I/O error rather than silent
  corruption. Not observed in testing. If it happens, enlarge the buffer with
  `swiotlb=131072` (256 MB instead of the default 64 MB).
- **`DMA_ATTR_MMIO` / `DMA_ATTR_REQUIRE_COHERENT`** mappings return an error
  under forced bouncing. No USB path is known to use them, and nothing was
  observed, but it is a theoretical hazard.
- **Every USB device on an xHCI controller is bounced**, not just storage. For
  keyboards, mice and Bluetooth the extra memcpy is irrelevant.
- **It does not fix the cause.** The pages are still mis-declared, so another
  device doing DMA — the GPU, the internal NVMe — could still trip the same
  Data Fabric refusal. It would no longer *freeze* the machine, because the
  freeze came from the xHCI waiting forever, not from the machine check itself.
- **No data corruption risk.** swiotlb bouncing is the standard path on every
  machine that has a 32-bit DMA device; this patch only changes *which* devices
  take it.
- **Not upstream material as written.** Defaulting the flag on for all xHCI
  controllers is fine for a PS5-only kernel but wrong in general; upstream
  would want it gated on platform detection.

## Credits

- [rmuxnet/ps5-linux-patches-1](https://github.com/rmuxnet/ps5-linux-patches-1)
  — the kernel patch set and build system this was developed against. Its
  `build.sh` does the real work of building and deploying.
- The PS5 Linux loader is sonic_iso's work. The memory map it hands to Linux is
  where this bug ultimately lives.

## Licence

`SPDX-License-Identifier: GPL-2.0` — the patched files are part of the Linux
kernel and this patch inherits its licence. See
<https://www.kernel.org/doc/html/latest/process/license-rules.html>.
