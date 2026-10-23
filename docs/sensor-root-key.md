# Touch ID root-key extraction

The Neo sensor needs a complete device-local combined root-key container. A bare `IMG4` containing an `MSRk` payload is not sufficient. Keep the outer `comb`, its `fdrd` image and manifest, and its `secb` trust bundle byte-for-byte. Never synthesize a manifest or combine records from different machines.

The `root_key` parser checks the envelope and preserves the supplied bytes. `collect()` never includes the record: the adapter stages it by itself (see Staging). These checks are structural only; they do not establish a valid certificate chain or sensor binding.

## Source

macOS keeps the records in `/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata`, on the Hardware volume of the Mac's own iBoot System Container, readable without root. `factory_root_key()` rebuilds the container from three of them:

- `MSRk-<sensor>`: an `IMG4` whose `IM4P` carries the key. Its own factory manifest chains to a root the enclave does not trust, so only the `IM4P` is used.
- `seal-<ECID>`: the FDR sealing manifest (`IM4M`), which does chain to `secb`.
- `trustobject-<sha256>`: the trust bundle, used as `secb`. It is the named bundle whose bytes and digest match `trustobject-current`; older bundles that a macOS update leaves in the cache are ignored. Without `trustobject-current`, exactly one named bundle must be present and match its name.

The result is `comb { fdrd: IMG4 { IM4P(MSRk), [0] seal }, secb: trustobject }`. That's the layout macOS uses for the other records in the same cache (`appv`, `fCfg` carry the same seal and trust bundle), so no manifest is synthesized and nothing crosses machines. Exactly one `MSRk` and one `seal` record are required, and anything missing, ambiguous or mismatched is rejected.

On a Touch ID-equipped Neo (macOS 26.6.2, 25G83) this rebuilds a 12,688-byte container, byte-identical to the one captured from macOS that already brings the sensor up on Linux and enrols. `root_key()` accepts it.

## Calibration

The calibration that `collect()` carves from the iBoot System Container is either an FSCl `comb` record or a standalone signed FSC2 `IMG4`. The enclave loads only the combined layout: it refuses the plain FSC2 image (`LOAD_CALIBRATION` fails), and accepts the same `IM4P` under this Mac's `seal-<ECID>` with the trust bundle as `secb`, the same records the root key uses. `factory_calibration()` rebuilds it that way, and `collect()` writes the result as `apple/mesacal-j700.bin`, so the copy in `vendorfw` that Linux loads after every boot is the sealed one. An FSCl record already has this layout and is kept as it is. If the factory records are missing, collection of a standalone FSC2 calibration fails rather than installing a file the enclave refuses.

The calibration is not the device-private key, so its collection stays on by default.

## Staging

The adapter rebuilds the key on every MacBook Neo with a Touch ID sensor, and keeps it only when the calibration was collected too, since the key is no use without it. A key that can't be rebuilt is logged, and the install goes on without Touch ID.

The key never joins the vendor firmware package. `install_stub_and_esp` writes it to the ESP by itself, as `vendorfw/touchid/msrk-j700.bin`, after asahi-installer has copied the package there. It is written to a temporary name and renamed, so a write interrupted before the rename never takes the key's name. FAT has no journal and macOS's fsync doesn't flush the drive's cache, so a power cut can still leave a damaged file under that name, and Linux checks the key's DER envelope before it uses it. A failure is logged and costs Touch ID only. Each copy of the key, and of the records it is rebuilt from, is accounted for:

- **The firmware archives:** `vendorfw/firmware.tar` and `vendorfw/firmware.cpio` don't carry it, and the initramfs unpacks only `firmware.cpio`.
- **Recovery:** the per-install Recovery firmware baseline (`Recovery/README.md`) copies only the files it names, `firmware.tar`, `firmware.cpio`, `manifest.txt` and the optional ASMedia firmware, never the `vendorfw` directory, so `Aurora/Recovery/InstallData/AuraPayloads` never holds it.
- **The ESP:** FAT holds no per-file modes. Our images mount it with `umask=0077`, so on Linux only root can read the staged copy. At Linux's first boot, omarchy-mac's Touch ID status unit moves it to `/var/lib/omarchy-mac/msrk-j700.bin`, root-owned `0600` in a `0700` directory, and deletes the ESP copy (omacom/omarchy-mac-pkgs#12). On macOS the staged copy has the ESP mount's permissions while the installer has the ESP mounted. That exposes nothing new there, since the factory records it is rebuilt from are readable without root.
- **The fallback firmware archive:** upstream asahi-installer's `collect_firmware` tars the whole `com.apple.factorydata` cache into `all_firmware.tar.gz`, adds it to `copy_idata`, which `collect_installer_data` copies into the ESP's `asahi/` on every install, on every Mac. That cache holds the `MSRk-*`, `seal-*` and trust bundle records the key is rebuilt from. It is inherited from upstream, root-only on Linux through the same `umask=0077` mount, and not removed by omacom/omarchy-mac-pkgs#12.
- **The installed system:** omarchy-mac copies it into `/usr/lib/firmware/updates/apple/msrk-j700.bin`, `0600`, only after the owner agrees to turn Touch ID on. A factory reset carries the kept copy into the factory root.

A Neo installed before this, or reinstalled from Recovery, has no staged key, and Linux doesn't offer it Touch ID.

This work is separate from country-policy extraction and encryption recovery. It does not change either path or enable fingerprint setup by default.

The root-key record is device-private. On the ESP it is root-only on Linux through the `umask=0077` mount; in `/var/lib/omarchy-mac` and on the installed system it is root-owned `0600`, in a `0700` directory where omarchy-mac creates one. General world-readable firmware defaults are unsuitable for this record.
