# Try Omarchy in a window

The installer can run Omarchy in a virtual machine before anyone installs it. The design record is Try Omarchy's [installer trial plan](https://github.com/omacom/try-omarchy/blob/main/docs/installer-trial.md); how the VM runs is in its [VM kit and run mode](https://github.com/omacom/try-omarchy/blob/main/docs/vm-kit.md).

## What people see

- The first page offers **Try it in a window** beside **Continue**. The page for a Mac Omarchy can't be installed on offers it too. The page that refuses a Mac with Omarchy installed does not.
- Once Try Omarchy is installed, the button reads **Open in Try Omarchy** and opens it. Try Omarchy then owns the VM.
- The Try screen offers Accessibility, so ⌘ works as Super, and the microphone and camera. All three are optional. It shows the space the trial needs and the space free, and **Download and start** waits until there is room.
- While Omarchy runs, the page shows its state, **Shut Down** and, on a Mac the installer supports, **Install on this Mac**. Installing shuts Omarchy down first.
- Quitting the installer shuts Omarchy down first and shows **Shutting down** until it has. The installer's window can't be closed while Omarchy runs.
- The plan review notes the space the trial VM takes. The native install leaves it in place.

## How it is built

- `Packaging/try-omarchy-kit.json` pins the kit, `TryOmarchyKit.zip` from a Try Omarchy release, by URL, size and digest. It also pins the `TryOmarchyKitClient` sources vendored in `Vendor/`, from the same revision.
- `scripts/try_omarchy_kit.py vendor --source ../try-omarchy --release vX.Y.Z` updates both. Without `--release` it vendors the client only and leaves no kit pinned. `check` verifies the vendored client against the pin, and `test/all` runs it.
- `Packaging/build-app.sh` fetches the pinned kit, checks its digest, runs its launcher's inspect-only check, and places it in `Contents/Helpers`. With no kit pinned the app has no trial button. `OMARCHY_TRY_KIT_ZIP` embeds a locally built kit instead, checked against the `.sha256` beside it.
- `Packaging/sign-vm-kit` signs every Mach-O in the kit as the installer: QEMU with the hypervisor and microphone entitlements, the helper with the camera and microphone. The app itself is signed with the camera and microphone entitlements, and its `Info.plist` describes their use. `Packaging/release/sign-app` does the same for releases, and `release-guard` accepts the kit in `Contents/Helpers`.

## Testing

`TrialSessionTests` cover the trial's states and words. The trial itself is checked by hand on a Mac: a first start with and without each permission, shutting down from each place, the error while Try Omarchy runs the VM, and a second start. CI can't boot the VM.
