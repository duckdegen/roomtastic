# Working on Roomtastic

## Communication and scope

Use plain engineering English. Explain what changes, what the user will hear or see, and what was actually checked. Do not describe a successful build or simulated measurement as proof of speaker synchronization or room-correction accuracy.

Read [README.md](README.md) for setup, build, installation, operation, release, and removal instructions. Keep it aligned with executable behavior. Roomtastic is a native Mac audio app plus an iPhone measurement companion, not a website or hosted service.

## Project structure

- `RoomtasticMac` controls the separate `RoomtasticService` through `RoomtasticControl` and its same-user Unix socket.
- `RoomtasticService` reads the virtual stereo device, discovers outputs, runs corrected playback, and coordinates phone measurements. `RoomtasticDSP` implements the C++ audio path; `RoomtasticCalibration` analyzes recordings and verifies corrections.
- `RoomtasticShared` owns cross-platform data models; `RoomtasticTransport` owns encrypted phone communication. The iOS project references those two local Swift package products.
- The BlackHole-based driver is built with `packaging/RoomtasticDriver.h`. AirPlay sending comes from a pinned executable, not Apple's route-picker interface.
- User state is stored under `~/Library/Application Support/Roomtastic`. Credentials are stored separately in Keychain. Do not commit runtime state, recordings, pairing codes, credentials, or user-specific Xcode files.

## Setup and dependencies

Work from the repository root on an Apple Silicon Mac. Use full Xcode and set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or the actual full-Xcode path. Deployment targets are macOS 14 and iOS 17; use C++17 for audio code.

Initialize dependencies with `git submodule update --init --recursive` and verify with `python3 scripts/vendor.py --verify`. Read `Vendor/dependencies.lock.json` before changing vendor revisions. The dependency directories are Git submodules, not copied source trees. Preserve local changes; do not reset, clean, or replace vendor checkouts to suppress build failures.

A deliberate dependency update must keep submodule pointers, the lock file, recursive revisions, license notices/map, and any embedded sender-version references consistent. Do not edit pinned upstream source silently. Generated archives and patched static libraries do not belong in commits.

## Build, run, and checks

Use the exact commands in README.md:

- `xcrun swift build` checks Mac Swift package compilation; `./scripts/build.sh` assembles the actual app, driver, and sender.
- `xcrun swift test` runs shared-model, transport, and calibration tests. Compile and run `Tests/RoomtasticDSPTests/DSPTests.cpp` separately; it is not a SwiftPM test target.
- Build `iOS/RoomtasticPhone.xcodeproj`, scheme `RoomtasticPhone`, with a generic iOS destination and signing disabled for compilation checks. Device execution requires valid signing. Simulator success cannot validate LiDAR, microphone response, or acoustic timing.
- `./scripts/package.sh` creates installation artifacts; it does not install them. Review its staging behavior and explicit source-archive list when adding files that releases need.
- Inspect `git diff --check` and changes before finishing. Run checks appropriate to the change and report failures and hardware checks still outstanding. Documentation-only edits need command/path/link verification, not a complete audio rebuild.

Prefer non-installing builds and unit tests during development. Installing a driver, changing system output, enabling the root clock service, restarting audio services, and playing calibration sweeps affect the user's machine or room. Perform them only within the task's authorization. Never kill `coreaudiod` as a shortcut; installation/removal expects a restart.

Only one audio service may run per user. Stop the installed service before a foreground development run. `--discover` and `--status` provide diagnostics; `--run-for` runs the real service and can resume audio, so do not present it as a dry run. Keep the menu app and audio service unprivileged. Only the installed, root-owned shared-clock helper should run as root.

## Audio and calibration rules

- Preserve bounded audio buffers, explicit sample positions, and stale-frame rejection. Audio callbacks must not allocate, wait on locks, access files/network, or call into UI code. Keep state changes coordinated with the worker and output timeline.
- Use one coordinated playback timeline across wired and AirPlay outputs. Do not substitute identical wall-clock start requests for measured synchronization, and do not remove clock-drift compensation.
- Bypassing tone correction must retain timing compensation. Muting, preset changes, reconnects, and failures must not emit queued stale audio or abrupt full-volume samples.
- Restore the previous default output only if Roomtastic is still selected. Respect a user's later output change. Missing prior devices require a clear error, not an arbitrary replacement.
- Keep physical speaker placement separate from software-addressable output channels. A linked 2.1 system has two controllable input channels; its subwoofer is not a third output. Preserve common timing and joint correction constraints for linked hardware.
- Use acoustic reference recordings to account for phone/playback clock differences. Network message arrival times are not acoustic measurements. LiDAR geometry cannot replace sound measurements.
- Never mark a profile verified from predicted curves alone. Require fresh combined-system recordings and their saved evidence. Reject incomplete, mismatched, clipped, moving, or interrupted captures; keep the previous calibration on failure.
- Preserve configuration checks when room geometry, output assignment, channel layout, sample rate, or measurement conditions change. Saved profiles must restore their speaker sets; missing speakers must not silently turn a profile into a verified partial setup.
- Keep gain and correction bounds, finite-number checks, and room-cancellation limits. An iPhone microphone does not justify absolute response or SoundID-equivalent accuracy claims.

Changes to these behaviors need targeted regression tests. Hardware release checks should include two AirPort Express receivers and a wired output, linked 2.1 playback, a 30-minute timing run, fresh before/after measurements, disconnect/reconnect, sleep/wake, service failure, preset changes, and install/upgrade/uninstall.

## Interfaces and saved data

Validate cross-device messages and local control requests before changing state. Preserve same-user control-socket checks, encrypted pairing, message/upload bounds, capture IDs, and cancellation handling. Never log secrets or expose credentials through status responses. Status currently can include a pairing URI; redact it in shared diagnostics.

When modifying Codable models, protocol versions, or stored profiles, account for older saved data and both apps. Add migration/compatibility handling where needed; do not silently discard user profiles or fabricate verification evidence. Keep the MIT shared/iOS code independent of GPL-only Mac modules.

Raw recordings are opt-in. Preserve deletion controls and device-local storage. Avoid committing real room scans or recordings as fixtures; use generated data for repeatable tests.

## Deployment and operation

Consult README.md and the scripts rather than inventing release commands. Mac distribution uses a Developer ID-signed installer, notarization, and a corresponding-source archive. iPhone distribution uses Xcode archives and App Store Connect/TestFlight; there is no automated upload configured here.

`APPLICATION_IDENTITY`, `INSTALLER_IDENTITY`, `DEVELOPMENT_TEAM`, and `NOTARY_PROFILE` configure signed packaging. `VERSION` alone does not update embedded app/driver versions. Update their actual plist/build definitions consistently, and update the phone's literal plist versions as well as Xcode settings. Do not store signing credentials in the repository.

Read `LICENSES/license-map.json` before public binary distribution. It records unresolved permission for two files in the pinned AirPlay dependency. Do not remove that warning or claim it is resolved without evidence. Preserve upstream notices and provide complete corresponding source for distributed GPL binaries.

Operational tools are `scripts/service.sh` (user service), `scripts/enable-ptp.sh` (administrator timing service), `scripts/install.sh`, and `scripts/uninstall.sh`. Keep installation/removal restricted to Roomtastic-owned paths, preserve ownership/symlink checks, stop processes gracefully before replacement, and leave user presets intact during uninstall.

Do not publish releases, notarize/upload builds, or change production signing configuration merely to verify a local change. Prepare artifacts and report what remains unless those actions are part of the user's request.
