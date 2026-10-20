#!/usr/bin/env python3
"""Add an explicit interrupted-conversion case to the pinned disposable VM run."""
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = '''  serial_expect 'conversion finished' "conversion: conversion"
'''
new = '''  attach -P -r "$disk"; dev=$ATTACHED
  local probe=0 pending=0
  while (( probe < 60 )); do
    if sudo -n cryptsetup luksDump --dump-json-metadata "${dev}p3" >"$work/probe.json" 2>/dev/null &&
       python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(not any(s.get("type")=="reencrypt" for s in m["keyslots"].values()))' "$work/probe.json"; then
      pending=1
      break
    fi
    sleep 1
    probe=$((probe + 1))
  done
  detach_last
  (( pending == 1 )) || fail "no pending reencryption observed before interruption"
  sleep 2
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
if len(sys.argv) == 3:
    fix = pathlib.Path(sys.argv[2]).resolve()
    assert re.fullmatch(r"[A-Za-z0-9/_-]+", str(fix))
    replacements = [
        ("omarchy-mac-boot/files/usr/lib/omarchy/initcpio/omarchy-mac-encrypt", "usr/lib/omarchy/initcpio/omarchy-mac-encrypt"),
        ("omarchy-mac-boot/files/usr/lib/initcpio/install/omarchy-mac-encrypt", "usr/lib/initcpio/install/omarchy-mac-encrypt"),
    ]
    needle = '    chroot "$merged" bash -euo pipefail -c "$5" bash "$4"'
    assert source.count(needle) == 1
    installs = "\n".join(f'    install -m 755 "{fix / original}" "$merged/{target}"' for original, target in replacements)
    source = source.replace(needle, installs + "\n" + needle)
    needle = '      fail "dd ${part#*:}"\n  done\n}'
    assert source.count(needle) == 1
    installs = "\n".join(f'  sudo -n install -m 755 "{fix / original}" "$work/fix-root/{target}"' for original, target in replacements)
    patch = '\n  attach -P "$disk"; local patched=$ATTACHED\n  mkdir -p "$work/fix-root"\n  mount_tracked -o subvol=@ "${patched}p3" "$work/fix-root"\n' + installs + '\n  umount_last\n  detach_last\n'
    source = source.replace(needle, needle[:-2] + patch + "}")
if len(sys.argv) == 3:
    needle = '  first_boot_finished conversion'
    assert source.count(needle) == 1
    stale = '''  stop_guest
  attach -P "$disk"; dev=$ATTACHED
  mkdir -p "$work/boot"
  mount_tracked "${dev}p2" "$work/boot"
  sudo -n grep -qx 'phase=configured' "$work/boot/omarchy/encrypt.state" || fail "resume did not durably configure boot"
  sudo -n test ! -e "$work/boot/omarchy/luks-header-before-repair" || fail "completed recovery retained obsolete header"
  sudo -n sed -i 's/^phase=configured$/phase=reencrypting/' "$work/boot/omarchy/encrypt.state"
  sudo -n sync
  umount_last
  detach_last
  ok "stale journal: completed conversion with saved key and phase=reencrypting prepared"
  log=$evidence_dir/completed-journal-serial.log
  boot_guest "$disk" "$log" "$(limine_cmdline "$work/payload/esp/limine.conf")"
  serial_expect 'conversion already complete; finishing the saved boot transaction' "stale journal: completed conversion recognized"
  serial_expect 'sysroot.mount drop-in What=/dev/mapper/root' "stale journal: boot continued"
  first_boot_finished conversion'''
    source = source.replace(needle, stale)
path.write_text(source)
