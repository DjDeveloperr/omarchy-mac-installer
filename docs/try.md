# Try Omarchy in a VM

The installer is the one app for Omarchy on a Mac, with two modes. **Install** puts Omarchy on the Mac's own hardware. **Try** runs it in a virtual machine, in a window beside macOS. The design record is Try Omarchy's [one app plan](https://github.com/omacom/try-omarchy/blob/main/docs/one-app.md); how the VM runs is in its [VM kit and run mode](https://github.com/omacom/try-omarchy/blob/main/docs/vm-kit.md).

## What people see

- On a Mac the installer supports, the first page offers **Install on this Mac** and **Try in a VM**. Install continues into the plan. Try opens the Try page, whose **Back** returns to the choice.
- On a Mac Omarchy can't be installed on, the Try page opens at once. One line under the Mac's name says why. **Check again** is in the Installation menu.
- On a Mac with Omarchy installed, the Try page opens at once too, with a line saying so. **Remove Omarchy…** stays in the Installation menu. An install still waiting for its Recovery step shows the Recovery steps instead. If Omarchy started before the check found it, the running page says so, and the steps appear once Omarchy shuts down.
- The Try page offers Accessibility, so ⌘ works as Super, and the microphone and camera. All three are optional. It shows the space the virtual machine needs and the space free, and **Download and start** waits until there is room.
- While Omarchy runs, the page shows its state, **Shut Down** and, on a supported Mac, **Install on this Mac**, which shuts Omarchy down first. It lists any permission still not granted, with **Allow**; a grant takes effect at the next start.
- A virtual machine in the default folder is the remembered choice. The app opens into Try and starts Omarchy at once, and checks the Mac in the background. After Omarchy shuts down, the Try page stays, with **Start**.
- The Installation menu has **Install on this Mac…**, which shuts Omarchy down and continues into the plan, or says why this Mac can't install. **Delete Virtual Machine…** asks first, naming the most space it frees, with Cancel as the default button. It then moves the folder to the Trash and returns to the first page.
- Quitting shuts Omarchy down first and shows **Shutting down** until it has. The window can't be closed while Omarchy runs.
- When Try Omarchy, or another copy of this app, has the virtual machine open, starting fails and says so.
- The plan review notes the space the virtual machine takes, as an upper bound, because its disk shares blocks with the image it was cloned from. The native install leaves it in place.

## How it is built

- `TrialSession` is Try's state machine beside the installer's `InstallerSession`. It follows the installer's inspection through `TrialInstallStatus`, which decides whether the first page is the choice or the Try page.
- `LiveTrialEnvironment` runs the kit through `VMRunClient`, reads and requests this app's permissions, and uses the folder Try Omarchy uses, `Application Support/Try Omarchy/VM/v1`.
- `TrialVMFolder` deletes only that folder. It opens each folder down to `shell` without following links, takes the launcher's lock on `shell/lock`, creating it if needed, and checks the path again before the move. A running virtual machine is never moved, and the folder goes to the Trash, never deleted outright.
- `Packaging/try-omarchy-kit.json` pins the kit, `TryOmarchyKit.zip` from a Try Omarchy release, by URL, size and digest, with the release's revision and the version and run-mode protocol its `TryOmarchyKit.json` declares. It also pins the `TryOmarchyKitClient` sources vendored in `Vendor/`, from the same revision.
- `scripts/try_omarchy_kit.py vendor --source ../try-omarchy --release vX.Y.Z` updates both. It refuses a release whose `TryOmarchyKit.json` names another version or another protocol than the client's. Without `--release` it vendors the client only and leaves no kit pinned.
- `scripts/try_omarchy_kit.py check` verifies the vendored client against the pin, and that a pinned kit comes from the client's revision, is a release and never `development`, and speaks the client's `VMRunProtocol.version`. `check --online` also checks the release's tag and its `TryOmarchyKit.json` against the pin.
- `Packaging/build-app.sh` fetches the pinned kit, checks its digest, runs its launcher's inspect-only check, and places it in `Contents/Helpers`. With no kit pinned the app has no Try mode, and its pages are the installer's alone. `OMARCHY_TRY_KIT_ZIP` embeds a locally built kit instead, checked against the `.sha256` beside it.
- `Packaging/sign-vm-kit` signs every Mach-O in the kit as the installer: QEMU with the hypervisor and microphone entitlements, the helper with the camera and microphone. The app itself is signed with the camera and microphone entitlements, and its `Info.plist` describes their use. `Packaging/release/sign-app` does the same for releases, and `release-guard` accepts the kit in `Contents/Helpers`.
- `Packaging/release/check-try-kit` checks a signed app: each Mach-O in the kit signed as the installer with the hardened runtime, QEMU's and the helper's entitlements, the app's usage descriptions and entitlements, and the kit's `kit.json`. With no kit pinned it checks that the app carries none.

## Testing

`TrialSessionTests` cover the choice page, the Try page on an unsupported Mac and on one with Omarchy installed, Check again, the remembered choice and its auto-start, including one that fails, Install on this Mac, a pending Recovery step found while Omarchy runs, the running page's permissions, deleting the virtual machine, and the words for every error and progress step. In debug builds they also check the pages the simulated Macs land on. `TrialVMFolderTests` cover which folders deleting may touch, links on the way, a missing lock and a lock held by another process. The views, the menu and the alerts have no automated tests, and the simulation dashboard covers the installer only.

CI runs these tests in debug and release, and `test/macos-try-tests.sh` fails when one of the two suites runs no tests or a test is skipped. `test/all` runs the pin check and the tests for `try_omarchy_kit.py` and `check-try-kit`. CI also assembles the app with the pinned kit, signs it ad hoc and runs `check-try-kit` ([validation](validation.md#continuous-integration)). Until a release carries the kit, CI assembles the app without one and checks that it has no Try mode.

By hand on a Mac: the first launch on a supported Mac, an unsupported one and one with Omarchy installed; a second launch with a virtual machine; Install on this Mac from the running page and the menu; Delete Virtual Machine; and the error while Try Omarchy runs the virtual machine. CI can't boot the virtual machine.
