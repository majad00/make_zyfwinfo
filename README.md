# Make_zyfwinfo.sh

>`make_zyfwinfo.sh` creates a **rich-format `zyfwinfo` file** for Zyxel EX5601-T0 / T56 devices.

The tool starts from an existing OEM or known-good `zyfwinfo` template, preserves its unknown metadata, updates the fields needed for rich-format boot selection, recalculates the checksum, and verifies the completed file before reporting success.

The generated file can later be copied to the router and written to a `zyfwinfo` UBI volume.

---
> This script is part of the tool "Openwr loader",  https://github.com/majad00/ex5601_openwrt_loader/releases/tag/1.1

## What the script changes

The script preserves the template contents except for these fields:

| Offset | Size | Value / purpose |
|---|---:|---|
| `0x00` | 4 bytes | Must already contain `EXYZ` |
| `0x04` | 1 byte | Forced to `0x03` for rich format |
| `0x06` | 1 byte | Boot sequence supplied with `--seq` |
| `0x09` | 1 byte | Forced to `0x04` for rich format |
| `0x78` | 4 bytes | Rootfs load size, little-endian |
| `0xFE` | 2 bytes | Checksum, little-endian |

The checksum is calculated as:

```text
sum of bytes 0x00 through 0xFD, modulo 65536
```

The low checksum byte is stored at `0xFE`, and the high byte at `0xFF`.

The output is always at least `0x400` bytes because newer zloader versions may read `0x400` bytes from the `zyfwinfo` volume.

---

## Requirements

The script is written for a POSIX-style shell and uses common Unix utilities:

```text
awk
dd
grep
od
sed
tr
wc
```

Optional commands:

```text
hexdump
sha256sum
```

If `hexdump` is unavailable, the script uses `od` for its final preview.

Make the script executable:

```sh
chmod +x make_zyfwinfo.sh
```

Show built-in help:

```sh
./make_zyfwinfo.sh --help
```

---

## Required arguments

```text
--template FILE
```

Existing OEM or known-good `zyfwinfo` template.

The template:

- Must be at least 256 bytes.
- Must begin with the magic `EXYZ`.
- Should preferably come from the same model or firmware family.
- May be a 256-byte dump, a `0x400`-byte dump, or a complete UBI LEB dump.

```text
--output FILE
```

Destination filename for the generated rich `zyfwinfo`.

The input and output paths must be different.

```text
--seq N
```

Boot sequence byte from `0` to `255`.

Decimal and hexadecimal forms are supported:

```text
5
0x05
```

Normally the new sequence should be one higher than the currently active bank:

```text
new sequence = active sequence + 1
```

---

## Rootfs-size options

Choose exactly one of the following.

### Read the size from a SquashFS rootfs

```text
--rootfs FILE
```

The rootfs file must begin with little-endian SquashFS magic:

```text
hsqs
```

The script reads the 64-bit little-endian SquashFS `bytes_used` field at offset `0x28`, rounds it up to the next 4096-byte boundary, and stores the result at `zyfwinfo` offset `0x78`.

Example:

```sh
./make_zyfwinfo.sh \
    --template oem_zyfwinfo.bin \
    --output zyfwinfo.rich.bin \
    --seq 5 \
    --rootfs root.squashfs
```

### Supply the rootfs load size manually

```text
--rootfs-size N
```

The supplied value may be decimal or hexadecimal. It is rounded up to the next 4096-byte boundary.

Example:

```sh
./make_zyfwinfo.sh \
    --template oem_zyfwinfo.bin \
    --output zyfwinfo.rich.bin \
    --seq 5 \
    --rootfs-size 0x02ad5000
```

### Create metadata for an empty rootfs placeholder

```text
--empty-rootfs
```

This stores:

```text
0x00000000
```

at offset `0x78`.

This is useful for an initramfs staging bank where the `rootfs` UBI volume is intentionally empty.

Example:

```sh
./make_zyfwinfo.sh \
    --template oem_zyfwinfo.bin \
    --output zyfwinfo.initramfs.bin \
    --seq 8 \
    --empty-rootfs \
    --output-size 0x400
```

---

## Optional arguments

### Set the exact output size

```text
--output-size N
```

The output size must be at least 1024 bytes (`0x400`).

Decimal and hexadecimal forms are accepted.

If this option is omitted:

- The original template size is preserved when it is larger than 1024 bytes.
- Otherwise, the output is expanded to 1024 bytes.

Examples:

```sh
--output-size 0x400
```

```sh
--output-size 253952
```

`253952` bytes is a common EX5601-T0 UBI logical eraseblock size.

### Choose the padding byte

```text
--pad-byte ff
```

or:

```text
--pad-byte 00
```

Default:

```text
ff
```

Padding is only added when the requested output is larger than the template.

### Quiet mode

```text
--quiet
```

Suppresses the final verification report.

Errors are still printed.

---

## Complete examples

### Create a rich file from an OEM template and SquashFS rootfs

```sh
./make_zyfwinfo.sh \
    --template active_zyfwinfo.bin \
    --output target_zyfwinfo.bin \
    --seq 6 \
    --rootfs openwrt-rootfs.squashfs
```

### Create a `0x400`-byte rich file for initramfs staging

```sh
./make_zyfwinfo.sh \
    --template active_zyfwinfo.bin \
    --output target_zyfwinfo.bin \
    --seq 6 \
    --empty-rootfs \
    --output-size 0x400
```

### Create a complete LEB-sized output

```sh
./make_zyfwinfo.sh \
    --template active_zyfwinfo.bin \
    --output target_zyfwinfo.bin \
    --seq 6 \
    --rootfs openwrt-rootfs.squashfs \
    --output-size 253952 \
    --pad-byte ff
```

### Use a manually calculated rootfs load size

```sh
./make_zyfwinfo.sh \
    --template active_zyfwinfo.bin \
    --output target_zyfwinfo.bin \
    --seq 10 \
    --rootfs-size 0x02810000 \
    --output-size 253952
```

---

## Successful output

A normal successful run prints a report similar to:

```text
Rich zyfwinfo created successfully.
Template:             active_zyfwinfo.bin
Template size:        253952 bytes
Output:               target_zyfwinfo.bin
Output size:          253952 bytes
Magic:                EXYZ
Rich byte 0x04:       3
Sequence byte 0x06:   6
Rich byte 0x09:       4
Rootfs source:        SquashFS bytes_used=...
Rootfs load size:     0x02810000 (...)
Checksum calculated:  0x....
Checksum stored:      0x....
```

The script does not report success unless all final checks pass.

---

## Validation performed by the script

Before creating the output, the script verifies:

- The template exists.
- The template and output paths differ.
- The template is at least 256 bytes.
- The template begins with `EXYZ`.
- The sequence is between `0` and `255`.
- Exactly one rootfs-size source was selected.
- A supplied rootfs has `hsqs` SquashFS magic.
- The calculated load size fits in a 32-bit field.
- The requested output is at least `0x400` bytes.

After creating the output, it verifies:

- Magic remains `EXYZ`.
- Byte `0x04` is `3`.
- Sequence at `0x06` matches the requested value.
- Byte `0x09` is `4`.
- Rootfs load size at `0x78` is correct.
- Calculated and stored checksums match.
- The final output size is correct.

---

## Copying the file to the router

Example using `scp`:

```sh
scp target_zyfwinfo.bin root@192.168.1.1:/tmp/
```

Verify it on the router:

```sh
ls -l /tmp/target_zyfwinfo.bin
sha256sum /tmp/target_zyfwinfo.bin
hexdump -C /tmp/target_zyfwinfo.bin | head -32
```

Expected header pattern:

```text
45 58 59 5a 03 00 SS 00 00 04
```

Where `SS` is the selected sequence byte.

---

## Writing to a router

This utility only creates the file. It does **not** write NAND or UBI volumes.

Before writing anything:

- Confirm the target device and bank.
- Confirm the target volume is named `zyfwinfo`.
- Back up the current `zyfwinfo`.
- Confirm the new sequence is intentional.
- Confirm the rootfs-size field matches the rootfs in the same bank.

A typical UBI write may look like:

```sh
ubiupdatevol /dev/ubiX_Y /tmp/target_zyfwinfo.bin
```

The exact `/dev/ubiX_Y` path varies between routers and boot states. Resolve the volume by name instead of assuming fixed UBI numbers.

Read back and compare after writing:

```sh
dd if=/dev/ubiX_Y of=/tmp/zyfwinfo.readback.bin \
    bs=1 count="$(wc -c < /tmp/target_zyfwinfo.bin)"

cmp /tmp/target_zyfwinfo.bin /tmp/zyfwinfo.readback.bin
```

Do not reboot after a failed write or failed readback comparison.

---

## Extracting a template from a router

After identifying the correct active `zyfwinfo` UBI volume, copy at least `0x400` bytes:

```sh
dd if=/dev/ubiX_Y of=/tmp/oem_zyfwinfo.bin bs=1024 count=1
```

To preserve the complete logical eraseblock:

```sh
LEB_SIZE="$(cat /sys/class/ubi/ubiX/usable_eb_size)"

dd if=/dev/ubiX_Y of=/tmp/oem_zyfwinfo.bin \
    bs="$LEB_SIZE" count=1
```

Copy it to the computer:

```sh
scp root@192.168.1.1:/tmp/oem_zyfwinfo.bin .
```

---

## Troubleshooting

### `template magic is not EXYZ`

The supplied template is not a valid `zyfwinfo` file, or the dump began at the wrong offset.

Check:

```sh
dd if=oem_zyfwinfo.bin bs=4 count=1 2>/dev/null
```

Expected:

```text
EXYZ
```

### `rootfs is not little-endian SquashFS`

The supplied file does not begin with `hsqs`.

Check:

```sh
dd if=root.squashfs bs=4 count=1 2>/dev/null | hexdump -C
```

Expected bytes:

```text
68 73 71 73
```

### `choose exactly one rootfs size source`

Use only one of:

```text
--rootfs
--rootfs-size
--empty-rootfs
```

### `output must be at least 1024 bytes`

Rich-format output must be at least `0x400` bytes because newer zloader versions may read that amount.

### Sequence overflow

The sequence is one byte, so the accepted range is:

```text
0 through 255
```

The script does not implement wraparound automatically.

---

## Safety notes

`zyfwinfo` affects boot-bank selection and may contain firmware metadata used by zloader.

An incorrect sequence, checksum, rootfs size, or target volume can prevent the intended bank from booting.

Recommended workflow:

1. Back up both banks’ current `zyfwinfo` volumes.
2. Create the file from a template belonging to the same device or firmware family.
3. Verify the generated report.
4. Copy the file to the router.
5. Write only the intended inactive bank.
6. Read the complete file back and compare it.
7. Reboot only after successful verification.

---

## License and attribution

GPL v2
Written by Q-M
