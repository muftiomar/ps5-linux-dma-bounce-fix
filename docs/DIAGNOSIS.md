# How this was diagnosed

Everything below was measured on one console: a PS5 *fat* running Ubuntu
26.04.1 from `ps5-ubuntu2604.img.xz`, kernel `7.3.0-rc7-PinkSoup` built from
rmux's patch set, root filesystem on an NVMe drive in a HIKSEMI enclosure
(RTL9210, `0bda:9210`) attached to the front USB-C port and driven by UAS.

The method was deliberately boring: capture the failure twice with a kernel log
stream that survives the freeze, then compare the two captures byte for byte
before theorising.

## The causal chain

```
A device DMA write lands on a 4 KiB page the Data Fabric protects
        │
        ▼
Coherent Station raises Security Violation on all 16 instances
   (256-byte interleave: 16 × 256 = 4096 = exactly one page)
        │
        ▼
EN=0, DEFERRED=1  →  no exception is raised
PCC=0             →  the CPU carries on untouched
        │
        ▼
Linux logs "Hardware Error" and nothing else happens.
Nobody cancels the transfer.
        │
        ▼  +9 s   uas_eh_abort_handler on the Write(10)
        ▼  +14 s  xHCI host not responding to stop endpoint command
        ▼         xHCI host controller not responding, assume dead
        ▼         HC died; cleaning up
        ▼         usb 4-1: USB disconnect
        ▼         uas_eh_host_reset_handler FAILED to get lock err -19
        ▼         Device offlined / Aborting journal
        ▼
root filesystem read-only, sshd can no longer fork, machine frozen
```

The 9- and 14-second gaps are the point. The machine check comes **first**, and
it is not fatal — which is precisely why the result is a hang rather than a
panic.

## Decoding the machine check by hand

`edac_mce_amd` is not built into the PinkSoup config, so the log carries raw
registers. They decode as follows, using the kernel's own headers.

```
IPID = 0x0002002e_0000000d
```

From `arch/x86/include/asm/mce.h`:

```c
#define MCI_IPID_MCATYPE	0xFFFF0000
#define MCI_IPID_HWID		0xFFF
```

applied to the **high** half of the register: HWID = `0x2E`,
MCAType = `0x2`. From `arch/x86/kernel/cpu/mce/amd.c`:

```c
{ SMCA_CS,	 HWID_MCATYPE(0x2E, 0x0)	},
{ SMCA_CS_V2,	 HWID_MCATYPE(0x2E, 0x2)	},   /* ← this one */
{ SMCA_MA_LLC,	 HWID_MCATYPE(0x2E, 0x4)	},
{ SMCA_PIE,	 HWID_MCATYPE(0x2E, 0x1)	},
```

and `drivers/edac/mce_amd.c` names the bank:

```c
[SMCA_CS ... SMCA_CS_V2]	= "Coherent Station",
```

The extended error code comes from `XEC(x, mask) = ((x) >> 16) & mask` in
`mce.h`:

```
STATUS = 0xdc2030000002085b
XEC    = (STATUS >> 16) & 0x3f = 0x02
```

Kernel 7.3 no longer carries per-`xec` description tables for this bank, so the
label comes from the historical Coherent Slave table, where index 2 is
**Security Violation**. That is the single element of this decode that could not
be confirmed from the running machine's own sources.

The remaining status bits, all against the names in `mce.h`:

| bit | name | value | reading |
|----:|------|------:|---------|
| 63 | `VAL` | 1 | valid |
| 62 | `OVER` | 1 | further errors were lost |
| 61 | `UC` | 1 | uncorrected |
| 60 | `EN` | 0 | **no `#MC` exception from this bank** |
| 59 | `MISCV` | 1 | MISC register valid |
| 58 | `ADDRV` | 1 | the address can be trusted |
| 57 | `PCC` | 0 | **CPU context intact** |
| 53 | `SYNDV` | 1 | syndrome valid |
| 44 | `DEFERRED` | 1 | **deferred** |
| 43 | `POISON` | 0 | no poisoned data |

## The address pattern

Each failure reports sixteen banks, and their addresses are sixteen
consecutive 256-byte blocks — one page, interleaved across the sixteen
Coherent Station instances of the Data Fabric:

```
failure 1 (during a game download):  ADDR 1be50000 … 1be50f00
failure 2 (during a dd write load):  ADDR 02ad0000 … 02ad0f00
```

Both pages fall inside a range the e820 map calls usable:

```
BIOS-e820: [mem 0x0000000000100000-0x000000003fffbfff]  System RAM
```

and both are below the first gigabyte. The page is **different each time**, so
the protected memory is scattered rather than contiguous. That rules out a
simple `memmap=` exclusion: you would have to know every page in advance, and
the loader is the only component that could.

Neither address is inside the swiotlb buffer:

```
software IO TLB: mapped [mem 0x000000007b9d0000-0x000000007f9d0000] (64MB)
```

which is the observation the fix is built on. That window has been in use since
boot and has never offended the Data Fabric.

## What was ruled out, and how

Each of these was a plausible theory that a measurement killed. They are listed
because repeating them is a waste of anyone's evening.

| Hypothesis | Why it is wrong |
|---|---|
| IOMMU mapping problem | `iommu: Default domain type: Passthrough` — there are no translations to get wrong |
| The Salina 32-event cap in `xhci_handle_events()` | That controller never finishes probing (`Host halt failed, -110`), and `Salina: event ring appears stuck` appears in **no** capture |
| UAS vs BOT on the RTL9210 bridge | `usb-storage.quirks=0bda:9210:u` applied, froze anyway |
| Overheating | Drive temperature flat at 41 °C, `Critical Comp. Temperature Time: 0` |
| USB port power, rest-mode related | The enclosure's LED stays lit straight through the failure |
| Link power management | The kernel had already disabled LPM at boot |
| The HID receiver sharing the controller | Survived 65 minutes with it moved; `dd` then reproduced the failure in under a minute anyway |
| Download bandwidth or the network | The line caps at 20 Mbit/s ≈ 2.5 MB/s; the failure reproduces at 665 MB/s from `/dev/zero`, with no network at all |

## Reproducing it in under a minute

The original reports all involve a long download, which makes the bug look
rare and slow. It is neither. A direct write load reproduces it in **well under
a minute**, which turns a one-hour test cycle into a one-minute one:

```sh
./tools/reproduce.sh
```

On an unpatched kernel this ends with `dd: error writing ...: Read-only file
system` and a frozen machine. On a patched one it runs to completion.

Beware: each reproduction costs a full jailbreak cycle, because the root
filesystem has to be remounted and a reboot from inside Linux hands control
back to the PS5 firmware.

## What this does not explain

- **Why those particular pages.** Identifying the protected ranges means
  reverse engineering the loader. A first look at `1360linux.elf` found no
  `e820` symbols, but several of the memory-map boundaries visible in `dmesg`
  (`0x64829000`, `0x7f9d0000`, `0x3fffc000`, `0xe0700000`) appear as literals
  in the binary — which suggests a **static, hand-written** map rather than one
  queried from the firmware. That is the thread to pull for a real fix.
- **Whether other devices hit the same pages.** The GPU and the internal NVMe
  also do DMA. A refusal there would corrupt a transfer or log a machine check
  without hanging anything, so it would go unnoticed.
