#!/usr/bin/env python3
"""Add an explicit interrupted-conversion case to the pinned disposable VM run."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = '''  serial_expect 'conversion finished' "conversion: conversion"
'''
new = '''  sleep 5
  ! grep -aq 'conversion finished' "$log" || fail "interruption missed the conversion window"
  stop_guest
  attach -P "$disk"; dev=$ATTACHED
  sudo -n cryptsetup luksDump --dump-json-metadata "${dev}p3" >"$evidence_dir/interrupted-luks-metadata.json"
  python3 - "$evidence_dir/interrupted-luks-metadata.json" <<'CHECK'
import json, sys
metadata = json.load(open(sys.argv[1]))
assert any(slot.get("type") == "reencrypt" for slot in metadata["keyslots"].values()), "no pending reencryption keyslot"
CHECK
  mkdir -p "$work/boot"
  mount_tracked -o ro "${dev}p2" "$work/boot"
  sudo -n cat "$work/boot/omarchy/encrypt.state" >"$evidence_dir/interrupted-encrypt.state"
  grep -qx 'phase=reencrypting' "$evidence_dir/interrupted-encrypt.state" || fail "interruption did not retain phase=reencrypting"
  [[ $(sudo -n stat -c %s "$work/boot/omarchy/luks-key") == 64 ]] || fail "interruption lost temporary key"
  umount_last
  detach_last
  ok "interruption: stopped guest with pending LUKS reencryption, matching state and durable 64-byte key"
  log=$evidence_dir/resume-serial.log
  boot_guest "$disk" "$log" "$(limine_cmdline "$work/payload/esp/limine.conf")"
  serial_expect 'resuming interrupted LUKS2 reencrypt' "conversion: resume start"
  serial_expect 'resume finished' "conversion: resume completion"
'''
assert source.count(old) == 1
source = source.replace(old, new)
source = source.replace(
    "conversion=$(grep -a -o 'conversion finished in [0-9]*s ([0-9]* MiB/s)' \"$log\" | tail -n 1)",
    "conversion=$(grep -a -o 'resume finished in [0-9]*s' \"$log\" | tail -n 1)",
)
path.write_text(source)
