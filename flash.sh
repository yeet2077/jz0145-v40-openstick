#!/usr/bin/env bash
# Install OpenStick Debian on a JZ0145 v40 (MSM8916) 4G dongle.
#
# This script repeats the steps that worked on a JZ0145 v40 board by hand.
# It has not been run end-to-end as one script. Read it before running it,
# and run it one stage at a time if you're unsure (see --help).
#
# WARNING: this rewrites the bootloader and partition table. Keep the
# backup this script makes. Recovery is always possible through EDL
# (hold the reset button while plugging in), because EDL lives in the SoC ROM.

set -euo pipefail

RELEASE_URL="https://github.com/kinsamanka/OpenStick-Builder/releases/download/v0.2/openstick-debian.zip"
RELEASE_SHA256="89aee177b6bab23b28748188d75cda38c702c5813fe4135d27a9540735dc7fca"
DTB="msm8916-jz01-45-v33.dtb"   # the v33 device tree works on v40
OEM_PARTS="fsc fsg modem modemst1 modemst2 persist sec"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
BACKUP="${BACKUP:-$HERE/backup}"

usage() {
  cat <<EOF
usage: $0 [stage]

stages (default: all, in order):
  prepare   download OpenStick-Builder v0.2 and patch the boot image dtb
  backup    full eMMC dump + OEM partitions via EDL       (needs EDL mode)
  lk1st     write lk1st to aboot, wipe boot, reset       (needs EDL mode)
  flash     flash GPT, firmware, cdt, boot, rootfs       (needs fastboot)
  restore   restore OEM partitions, then reboot          (needs fastboot)

env: WORK=$WORK  BACKUP=$BACKUP
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "==> $*"; }

find_debugfs() {
  if command -v debugfs >/dev/null 2>&1; then command -v debugfs; return; fi
  if command -v brew >/dev/null 2>&1 && [ -x "$(brew --prefix e2fsprogs 2>/dev/null)/sbin/debugfs" ]; then
    echo "$(brew --prefix e2fsprogs)/sbin/debugfs"; return
  fi
  for p in /sbin/debugfs /usr/sbin/debugfs; do [ -x "$p" ] && { echo "$p"; return; }; done
  die "debugfs not found (install e2fsprogs)"
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

wait_edl() {
  echo "Put the dongle in EDL mode: hold the reset button while plugging it in."
  read -r -p "Press Enter when it is plugged in... " _
  edl printgpt >/dev/null 2>&1 || die "EDL not responding (expect USB 05c6:9008)"
}

wait_fastboot() {
  for _ in $(seq 1 45); do
    fastboot devices 2>/dev/null | grep -q fastboot && return 0
    sleep 1
  done
  echo "No fastboot device yet. Unplug the dongle, wait 5 s, plug it back in (no button)."
  read -r -p "Press Enter when replugged... " _
  for _ in $(seq 1 45); do
    fastboot devices 2>/dev/null | grep -q fastboot && return 0
    sleep 1
  done
  die "fastboot device not found"
}

fb_flash() {
  local out
  echo "  fastboot flash $1 $(basename "$2")"
  out="$(fastboot flash "$1" "$2" 2>&1)" || { echo "$out"; die "flashing $1 failed"; }
  echo "$out" | grep -E '^Writing' | sed 's/^/    /'
  echo "$out" | grep -q 'FAILED' && { echo "$out"; die "flashing $1 failed"; }
  return 0
}

stage_prepare() {
  say "prepare: download and patch OpenStick-Builder v0.2"
  need curl; need unzip; need python3
  local DEBUGFS; DEBUGFS="$(find_debugfs)"
  mkdir -p "$WORK"; cd "$WORK"
  [ -f openstick-debian.zip ] || curl -fL -o openstick-debian.zip "$RELEASE_URL"
  [ "$(sha256 openstick-debian.zip)" = "$RELEASE_SHA256" ] || die "checksum mismatch for openstick-debian.zip"
  unzip -o -q openstick-debian.zip

  # boot.bin is a sparse ext2 image whose extlinux.conf points at the UZ801 dtb.
  python3 "$HERE/tools/unsparse.py" boot.bin boot-jz0145.img
  "$DEBUGFS" -R 'cat /extlinux/extlinux.conf' boot-jz0145.img 2>/dev/null \
    | sed "s#fdt /dtbs/qcom/[^ ]*#fdt /dtbs/qcom/$DTB#" > extlinux.conf
  grep -q "$DTB" extlinux.conf || die "failed to patch extlinux.conf"
  "$DEBUGFS" -R "stat /dtbs/qcom/$DTB" boot-jz0145.img >/dev/null 2>&1 || die "$DTB missing from boot image"
  "$DEBUGFS" -w -R 'rm /extlinux/extlinux.conf' boot-jz0145.img >/dev/null 2>&1
  "$DEBUGFS" -w -R 'write extlinux.conf /extlinux/extlinux.conf' boot-jz0145.img >/dev/null 2>&1
  echo "  extlinux.conf now:"; "$DEBUGFS" -R 'cat /extlinux/extlinux.conf' boot-jz0145.img 2>/dev/null | sed 's/^/    /'
  dd if=/dev/zero of=zero1m.bin bs=1048576 count=1 2>/dev/null
}

stage_backup() {
  say "backup: dump eMMC and OEM partitions"
  need edl
  mkdir -p "$BACKUP"; cd "$BACKUP"
  wait_edl
  if [ ! -s orig_fw.bin ]; then
    edl rf orig_fw.bin
  else
    echo "  orig_fw.bin already exists, skipping full dump"
  fi
  for p in $OEM_PARTS; do
    [ -s "$p.bin" ] || edl r "$p" "$p.bin" >/dev/null
    [ -s "$p.bin" ] || die "backup of $p failed"
    printf "  %-9s %10s bytes\n" "$p" "$(wc -c < "$p.bin" | tr -d ' ')"
  done
  echo "  Keep $BACKUP somewhere safe. modemst1/modemst2/fsg/persist hold your IMEI and calibration."
}

stage_lk1st() {
  say "lk1st: write lk1st to aboot and wipe boot"
  need edl
  cd "$WORK"
  edl printgpt >/dev/null 2>&1 || wait_edl
  edl w aboot aboot.mbn
  # 'edl e boot' did not erase anything on this board; overwrite the header instead
  edl w boot zero1m.bin
  edl reset || true
  wait_fastboot
  fastboot getvar product 2>&1 | head -1
}

stage_flash() {
  say "flash: GPT, db410c firmware, cdt, qhypstub, lk1st, boot, rootfs"
  need fastboot
  cd "$WORK"
  wait_fastboot
  fb_flash partition gpt_both0.bin
  fb_flash aboot aboot.mbn
  fb_flash hyp hyp.mbn
  fb_flash rpm rpm.mbn
  fb_flash sbl1 sbl1.mbn
  fb_flash tz tz.mbn
  # The OpenStick-Builder README skips this. Without cdt the db410c sbl1
  # cannot set up DDR on this board and it falls back to EDL.
  fb_flash cdt sbc_1.0_8016.bin
  fb_flash boot boot-jz0145.img
  echo "  rootfs takes ~10 minutes..."
  fb_flash rootfs rootfs.bin
}

stage_restore() {
  say "restore: OEM partitions"
  need fastboot
  cd "$BACKUP"
  wait_fastboot
  for p in $OEM_PARTS; do fb_flash "$p" "$p.bin"; done
  fastboot reboot
  echo
  echo "Done. After ~1 minute, join WiFi 'Openstick' (password 'openstick')"
  echo "and run: ssh user@192.168.4.1   (password '1'; change it)"
}

case "${1:-all}" in
  prepare) stage_prepare ;;
  backup)  stage_backup ;;
  lk1st)   stage_lk1st ;;
  flash)   stage_flash ;;
  restore) stage_restore ;;
  all)     stage_prepare; stage_backup; stage_lk1st; stage_flash; stage_restore ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
