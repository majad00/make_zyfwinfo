#!/bin/sh
# written by Qureshi
# Create an EX5601-T0/T56 rich zyfwinfo file from an existing template.
# The template preserves unknown OEM metadata. Output is always >= 0x400 bytes.

set -eu

PROG="${0##*/}"
TEMPLATE=""
OUTPUT=""
SEQ=""
ROOTFS=""
ROOTFS_SIZE=""
EMPTY_ROOTFS=0
OUTPUT_SIZE=""
PAD="ff"
QUIET=0

usage() {
	cat <<USAGE
Usage:
  $PROG --template FILE --output FILE --seq N \\
      (--rootfs FILE | --rootfs-size N | --empty-rootfs) [options]

Required:
  --template FILE       Existing OEM/known-good zyfwinfo template.
  --output FILE         Output filename.
  --seq N               Sequence byte, 0..255 (decimal or 0xHEX).

Choose exactly one:
  --rootfs FILE         Read SquashFS bytes_used at 0x28 and round to 4 KiB.
  --rootfs-size N       Use explicit rootfs load size, rounded to 4 KiB.
  --empty-rootfs        Store zero at zyfwinfo offset 0x78.

Options:
  --output-size N       Exact output size. Minimum 1024 (0x400).
                        Default: preserve template size, minimum 1024.
  --pad-byte ff|00      Padding if output is larger than template. Default ff.
  --quiet               Do not print the verification report.
  -h, --help            Show help.

Examples:
  $PROG --template oem.bin --output rich.bin --seq 5 --rootfs root.squashfs
  $PROG --template oem.bin --output rich.bin --seq 8 --empty-rootfs --output-size 0x400
  $PROG --template oem.bin --output rich.bin --seq 9 --rootfs-size 0x02ad5000
USAGE
}

fail() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
size_of() { wc -c < "$1" | awk '{print $1}'; }

parse_uint() {
	local v
	case "$1" in
		0x[0-9a-fA-F]*|0X[0-9a-fA-F]*)
			[ "${#1}" -gt 2 ] || fail "invalid number: $1"
			echo $(( $1 ))
			;;
		*[!0-9]*|'') fail "invalid number: $1" ;;
		*)
			v="$(printf '%s' "$1" | sed 's/^0*//')"
			[ -n "$v" ] || v=0
			echo "$v"
			;;
	esac
}

read_byte() {
	dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -t u1 | awk '{print $1; exit}'
}

write_byte() {
	local file off val
	file="$1"; off="$2"; val="$3"
	[ "$val" -ge 0 ] && [ "$val" -le 255 ] || fail "byte out of range: $val"
	printf "\\$(printf '%03o' "$val")" | dd of="$file" bs=1 seek="$off" conv=notrunc 2>/dev/null
}

read_le32() {
	local file off
	file="$1"; off="$2"
	set -- $(dd if="$file" bs=1 skip="$off" count=4 2>/dev/null | od -An -t u1)
	[ "$#" -eq 4 ] || fail "cannot read LE32 at offset $2"
	echo $(( $1 + $2*256 + $3*65536 + $4*16777216 ))
}

write_le32() {
	local file off val
	file="$1"; off="$2"; val="$3"
	[ "$val" -ge 0 ] && [ "$val" -le 4294967295 ] || fail "LE32 out of range: $val"
	write_byte "$file" "$off"       $(( val        & 255 ))
	write_byte "$file" $((off + 1)) $(( (val >> 8)  & 255 ))
	write_byte "$file" $((off + 2)) $(( (val >> 16) & 255 ))
	write_byte "$file" $((off + 3)) $(( (val >> 24) & 255 ))
}

read_le64() {
	local file off
	file="$1"; off="$2"
	set -- $(dd if="$file" bs=1 skip="$off" count=8 2>/dev/null | od -An -t u1)
	[ "$#" -eq 8 ] || fail "cannot read LE64 at offset $2"
	echo $(( $1 + $2*256 + $3*65536 + $4*16777216 + \
	          $5*4294967296 + $6*1099511627776 + \
	          $7*281474976710656 + $8*72057594037927936 ))
}

round4k() { echo $(( (($1 + 4095) / 4096) * 4096 )); }

checksum_calc() {
	dd if="$1" bs=1 count=254 2>/dev/null | od -An -v -t u1 |
	awk '{ for (i=1; i<=NF; i++) s += $i } END { print s % 65536 }'
}

checksum_read() {
	local lo hi
	lo="$(read_byte "$1" 254)"; hi="$(read_byte "$1" 255)"
	echo $((lo + hi*256))
}

checksum_write() {
	local file cs
	file="$1"
	write_byte "$file" 254 0
	write_byte "$file" 255 0
	cs="$(checksum_calc "$file")"
	write_byte "$file" 254 $((cs & 255))
	write_byte "$file" 255 $(((cs >> 8) & 255))
	echo "$cs"
}

copy_resize() {
	local tpl out outsz tplsz cpsz remain
	tpl="$1"; out="$2"; outsz="$3"; tplsz="$(size_of "$tpl")"
	: > "$out" || fail "cannot create $out"
	if [ "$tplsz" -lt "$outsz" ]; then cpsz="$tplsz"; else cpsz="$outsz"; fi
	dd if="$tpl" of="$out" bs=1 count="$cpsz" 2>/dev/null || fail "template copy failed"
	remain=$((outsz - cpsz))
	[ "$remain" -gt 0 ] || return 0
	case "$PAD" in
		00) dd if=/dev/zero bs=1 count="$remain" 2>/dev/null >> "$out" || fail "padding failed" ;;
		ff) dd if=/dev/zero bs=1 count="$remain" 2>/dev/null | tr '\000' '\377' >> "$out" || fail "padding failed" ;;
		*) fail "invalid pad byte: $PAD" ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--template|--base) [ "$#" -ge 2 ] || fail "$1 needs FILE"; TEMPLATE="$2"; shift 2 ;;
		--output|-o) [ "$#" -ge 2 ] || fail "$1 needs FILE"; OUTPUT="$2"; shift 2 ;;
		--seq|--sequence) [ "$#" -ge 2 ] || fail "$1 needs N"; SEQ="$2"; shift 2 ;;
		--rootfs) [ "$#" -ge 2 ] || fail "$1 needs FILE"; ROOTFS="$2"; shift 2 ;;
		--rootfs-size) [ "$#" -ge 2 ] || fail "$1 needs N"; ROOTFS_SIZE="$2"; shift 2 ;;
		--empty-rootfs) EMPTY_ROOTFS=1; shift ;;
		--output-size) [ "$#" -ge 2 ] || fail "$1 needs N"; OUTPUT_SIZE="$2"; shift 2 ;;
		--pad-byte) [ "$#" -ge 2 ] || fail "$1 needs ff or 00"; PAD="$2"; shift 2 ;;
		--quiet) QUIET=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) fail "unknown argument: $1" ;;
	esac
done

for c in awk dd grep od sed tr wc; do need "$c"; done

[ -n "$TEMPLATE" ] || fail "--template is required"
[ -n "$OUTPUT" ] || fail "--output is required"
[ -n "$SEQ" ] || fail "--seq is required"
[ -f "$TEMPLATE" ] || fail "template not found: $TEMPLATE"
[ "$TEMPLATE" != "$OUTPUT" ] || fail "template and output must differ"

SEQ_DEC="$(parse_uint "$SEQ")"
[ "$SEQ_DEC" -ge 0 ] && [ "$SEQ_DEC" -le 255 ] || fail "sequence must be 0..255"

sources=0
[ -n "$ROOTFS" ] && sources=$((sources+1))
[ -n "$ROOTFS_SIZE" ] && sources=$((sources+1))
[ "$EMPTY_ROOTFS" -eq 1 ] && sources=$((sources+1))
[ "$sources" -eq 1 ] || fail "choose exactly one rootfs size source"

TPL_SIZE="$(size_of "$TEMPLATE")"
[ "$TPL_SIZE" -ge 256 ] || fail "template must be at least 256 bytes"
MAGIC="$(dd if="$TEMPLATE" bs=4 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')"
[ "$MAGIC" = "4558595a" ] || fail "template magic is not EXYZ: $MAGIC"

if [ -n "$OUTPUT_SIZE" ]; then
	OUT_SIZE="$(parse_uint "$OUTPUT_SIZE")"
elif [ "$TPL_SIZE" -gt 1024 ]; then
	OUT_SIZE="$TPL_SIZE"
else
	OUT_SIZE=1024
fi
[ "$OUT_SIZE" -ge 1024 ] || fail "output must be at least 1024 bytes"
case "$PAD" in ff|00) ;; *) fail "--pad-byte must be ff or 00" ;; esac

if [ -n "$ROOTFS" ]; then
	[ -f "$ROOTFS" ] || fail "rootfs not found: $ROOTFS"
	RFMAGIC="$(dd if="$ROOTFS" bs=4 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')"
	[ "$RFMAGIC" = "68737173" ] || fail "rootfs is not little-endian SquashFS (hsqs): $RFMAGIC"
	BYTES_USED="$(read_le64 "$ROOTFS" 40)"
	[ "$BYTES_USED" -gt 0 ] || fail "invalid SquashFS bytes_used"
	LOAD_SIZE="$(round4k "$BYTES_USED")"
	SOURCE="SquashFS bytes_used=$BYTES_USED from $ROOTFS"
elif [ -n "$ROOTFS_SIZE" ]; then
	RAW_SIZE="$(parse_uint "$ROOTFS_SIZE")"
	LOAD_SIZE="$(round4k "$RAW_SIZE")"
	SOURCE="explicit size=$RAW_SIZE"
else
	LOAD_SIZE=0
	SOURCE="empty rootfs"
fi
[ "$LOAD_SIZE" -le 4294967295 ] || fail "rootfs load size exceeds 32-bit field"

copy_resize "$TEMPLATE" "$OUTPUT" "$OUT_SIZE"

# Force rich format and requested boot metadata.
write_byte "$OUTPUT" 4 3
write_byte "$OUTPUT" 6 "$SEQ_DEC"
write_byte "$OUTPUT" 9 4
write_le32 "$OUTPUT" 120 "$LOAD_SIZE"
CS="$(checksum_write "$OUTPUT")"

# Verify everything before reporting success.
FMAGIC="$(dd if="$OUTPUT" bs=4 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n')"
B04="$(read_byte "$OUTPUT" 4)"
FSEQ="$(read_byte "$OUTPUT" 6)"
B09="$(read_byte "$OUTPUT" 9)"
FSIZE="$(read_le32 "$OUTPUT" 120)"
CCALC="$(checksum_calc "$OUTPUT")"
CSTORED="$(checksum_read "$OUTPUT")"
ACTUAL_SIZE="$(size_of "$OUTPUT")"

[ "$FMAGIC" = "4558595a" ] || fail "final magic verification failed"
[ "$B04" -eq 3 ] || fail "final byte 0x04 is not 3"
[ "$FSEQ" -eq "$SEQ_DEC" ] || fail "final sequence mismatch"
[ "$B09" -eq 4 ] || fail "final byte 0x09 is not 4"
[ "$FSIZE" -eq "$LOAD_SIZE" ] || fail "final rootfs size mismatch"
[ "$CCALC" -eq "$CSTORED" ] || fail "final checksum mismatch"
[ "$ACTUAL_SIZE" -eq "$OUT_SIZE" ] || fail "final output size mismatch"

if [ "$QUIET" -eq 0 ]; then
	echo "Rich zyfwinfo created successfully."
	echo "Template:             $TEMPLATE"
	echo "Template size:        $TPL_SIZE bytes"
	echo "Output:               $OUTPUT"
	echo "Output size:          $ACTUAL_SIZE bytes"
	echo "Magic:                EXYZ"
	echo "Rich byte 0x04:       $B04"
	echo "Sequence byte 0x06:   $FSEQ"
	echo "Rich byte 0x09:       $B09"
	echo "Rootfs source:        $SOURCE"
	printf 'Rootfs load size:     0x%08x (%s bytes)\n' "$FSIZE" "$FSIZE"
	printf 'Checksum calculated:  0x%04x\n' "$CCALC"
	printf 'Checksum stored:      0x%04x\n' "$CSTORED"
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$OUTPUT"; fi
	echo "First 0x100 bytes:"
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$OUTPUT" bs=256 count=1 2>/dev/null | hexdump -C
	else
		od -Ax -tx1 -N 256 "$OUTPUT"
	fi
fi
