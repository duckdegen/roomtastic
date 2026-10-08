# Roomtastic

Roomtastic is a Mac menu bar app that sends a normal stereo sound output to multiple wired and AirPlay devices. An iPhone companion scans the room with LiDAR and measures speakers to calculate timing, level, and frequency corrections for named listening positions.

Choose **Roomtastic** as your Mac output, select speakers in the menu bar, and recall a calibrated position as you move around the room. Each preset restores its speaker set. A linked 2.1 system is treated as a stereo system: its hardware still controls the subwoofer crossover and separate subwoofer timing.

This is development software. Successful builds and automated tests do not establish acoustic accuracy. The 1 ms synchronization target over 30 minutes and iPhone microphone accuracy require tests with actual receivers, speakers, and a reference microphone. Public binary distribution also has an unresolved upstream licensing prerequisite; see [Licensing](#licensing).

## Requirements

- Apple Silicon Mac running macOS 14 or later. Current packaging builds arm64 only.
- Full Xcode, including the macOS and iOS SDKs, with first-launch setup and license acceptance completed. Command Line Tools alone are insufficient for the iPhone app.
- Git, Python 3, and the compiler/build tools included with Xcode.
- AirPlay receivers and/or wired audio outputs. AirPort Express is an intended hardware target; compatibility depends on receiver firmware and must be tested.
- For scanning and calibration: a physical LiDAR-capable iPhone running iOS 17 or later. The simulator can build and exercise ordinary interface code but cannot validate LiDAR or microphone measurements.
- Mac, phone, and receivers on a network that allows device discovery and direct connections. Allow local-network access when requested.
- Administrator access for installing/removing the Mac driver and enabling the optional shared AirPlay clock. Ordinary audio playback runs as the signed-in user.

## Get the source

Run commands from the repository root unless stated otherwise:

```sh
git clone --recurse-submodules https://github.com/duckdegen/roomtastic.git
cd roomtastic
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/vendor.py --verify
```

For an existing clone, initialize dependencies with `git submodule update --init --recursive`. `Vendor/dependencies.lock.json` records exact upstream revisions. `python3 scripts/vendor.py` fetches the locked revisions; it refuses to overwrite modified tracked vendor files. Do not update dependencies to their latest branches just to make a build pass.

## Build and test

Build the Mac executables, virtual audio driver, and bundled AirPlay sender:

```sh
./scripts/build.sh
./scripts/package.sh
```

These commands create build files, not a system installation:

| Output | Purpose |
| --- | --- |
| `build/Roomtastic.app` | Menu bar app, audio service, and AirPlay helper |
| `build/driver/Release/Roomtastic.driver` | Virtual stereo audio device |
| `dist/Roomtastic-1.0.0.pkg` | Local installer |
| `dist/Roomtastic-1.0.0-source.tar.gz` | Source archive with recursive vendor sources and their Git metadata |

Without signing variables, the binaries receive local ad-hoc signatures. These are not Developer ID releases. `swift build` alone does not assemble an app bundle, driver, or AirPlay helper.

Run Swift tests and the separate C++ audio tests:

```sh
xcrun swift test
mkdir -p build
xcrun clang++ -std=c++17 -O2 -pthread -framework Accelerate \
  -ISources/RoomtasticDSP/include Sources/RoomtasticDSP/RoomtasticDSP.cpp \
  Tests/RoomtasticDSPTests/DSPTests.cpp -o build/roomtastic-dsp-tests
./build/roomtastic-dsp-tests
```

The C++ tests are not included in `swift test`. They check buffering, stale-audio rejection, clock drift, sample conversion, and processing without C++ heap allocation in the audio callback.

Playback continuously compares each output's sample position with its scheduled presentation time and gently adjusts sample conversion to correct accumulated error. Wired outputs publish hardware timestamps; AirPlay scheduling accounts for changes between the Mac's calendar and audio clocks. Clock jumps larger than 50 ms discard the affected session and trigger a fresh connection. **Room Setup → Connection Details** reports estimated timing error every five seconds while playing; this is a software estimate, not a microphone measurement of the speakers.

The timing regression includes 30-minute simulations at 44.1 and 48 kHz, imperfect clock-speed estimates, changing device speeds, and calendar-clock adjustment. To verify on hardware, play through an AirPort Express and the headphone output together for at least 30 minutes and compare their recorded relative delay near the beginning, at 10 minutes, and at the end. Also check reconnecting an output. A passing simulation alone does not establish audible synchronization.

Build the iPhone app without device signing:

```sh
xcodebuild -project iOS/RoomtasticPhone.xcodeproj \
  -scheme RoomtasticPhone -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/iOS CODE_SIGNING_ALLOWED=NO build
```

To run on a phone, open `iOS/RoomtasticPhone.xcodeproj` in Xcode, select the `RoomtasticPhone` target, choose your signing team and a bundle identifier your team can use, select the connected phone, and run. Complete any device trust/Developer Mode prompts. Grant camera, microphone, motion, and local-network permissions. The app is displayed as **Roomtastic Measure**. An unsigned build cannot be installed on a physical phone.

## Install and play

```sh
sudo ./scripts/install.sh dist/Roomtastic-1.0.0.pkg
```

Restart macOS after installation to load the audio driver. The scripts intentionally do not kill the system audio process. Installation places the app in `/Applications`, installs the driver under `/Library/Audio/Plug-Ins/HAL`, and installs a user background-service definition under `/Library/LaunchAgents`.

1. Open `/Applications/Roomtastic.app`. Its controls appear in the menu bar.
2. Select the wired and AirPlay outputs you want to hear.
3. Click **Start Playback**. This starts routing and selects Roomtastic as the system default output. Applications with their own output selector can choose Roomtastic explicitly while routing is active.
4. Allow microphone access if macOS requests it: the service reads the virtual audio input, rather than using the Mac microphone for room measurements.
5. Adjust the master volume or mute from the menu. Wired devices wait for the shared playback timeline; using AirPlay introduces delay for every selected output. Roomtastic does not delay video to compensate.

If a receiver reports **Shared AirPlay clock required**, enable the installed timing service:

```sh
sudo "/Library/Application Support/Roomtastic/enable-ptp.sh" enable
sudo launchctl print system/org.roomtastic.ptp
```

This separate root-owned service handles the shared AirPlay clock on UDP ports 319/320. It is not enabled by the installer. The audio service remains a user process. Disable the clock when no longer needed with the same script and `disable`.

Passwordless receivers connect automatically. If a receiver explicitly challenges authentication, open **Room Setup → Receiver requested authentication** and save its password in Keychain. The advanced fields accept existing pairing credentials; the interface does not implement a complete receiver PIN-pairing wizard. Never paste passwords or pairing credentials into issue reports.

**Stop Playback** stops routing and restores the previous default output if Roomtastic is still the default. **Quit Roomtastic** also shuts down the audio service. If the previous device is no longer available, select another output in macOS Sound settings. Apps explicitly assigned to Roomtastic may need their output changed separately.

## Scan, calibrate, and switch positions

1. Select the desired outputs on the Mac. Open **Room Setup**, then **Create Private Pairing QR Code**.
2. On the phone, use **Connect to Mac → Scan Pairing Code**. The code expires after five minutes and contains a secret. Later connections can use **Reconnect Saved Mac**.
3. Use **Scan Room**, then **Finish**. Add physical speakers and assign each one to the correct Mac output and channel. Mark their location, height, and facing direction. Receiver names alone do not tell the app where the speakers are.
4. For a 2.1 system, assign its left and right speakers to the receiver's two channels and add the subwoofer using **Add linked subwoofer**. Do not assign it a fictitious independent output.
5. Add a named listener position, such as Desk or Sofa, including ear height and facing direction. You can use tracked phone placement, camera placement where offered, or the room map. Re-align a saved room when the app requests it.
6. Set the listening position's bass/treble preference and optional left/right mix overrides. Keep speaker hardware volume and tone controls consistent during and after measurement.
7. Start calibration and follow the phone's guidance for the central ear position and eight nearby points. Keep the microphone unobstructed and consistently oriented; remain still during each sweep. Pause or cancel through the app when necessary.
8. Complete fresh verification measurements of the combined system. Only a passing result becomes a verified profile. Failed measurements retain the previous calibration.
9. Repeat for other named positions. Choose **Listening Position** in the Mac menu to recall a profile and its speaker selection. The phone is not needed for subsequent playback.

**Bypass Correction** bypasses tonal correction while keeping timing adjustments. Changing speaker selection clears the active preset. Missing outputs prevent a preset from replacing the current setup. Room, connection, format, and measurement-condition changes can require verification; the current implementation also includes master volume in its saved configuration check. Do not assume that a profile remains verified after changing it.

LiDAR provides geometry, not acoustic response. The phone's microphone is not an individually calibrated measurement microphone. Corrections are conservative, and cannot repair every cancellation caused by speaker placement. A linked subwoofer cannot be adjusted independently of its stereo hardware.

## Operate and troubleshoot

Manage the installed audio service as the signed-in user, without `sudo`:

```sh
"/Library/Application Support/Roomtastic/service.sh" status
"/Library/Application Support/Roomtastic/service.sh" restart
"/Applications/Roomtastic.app/Contents/MacOS/RoomtasticService" --status
"/Applications/Roomtastic.app/Contents/MacOS/RoomtasticService" --discover
```

`service.sh` also accepts `start` and `stop`. Restart interrupts playback. `--discover` runs an approximately eight-second discovery pass. `--status` returns JSON from the existing service; it does not start one. `--shutdown` requests graceful service exit. Status may contain a live pairing URI: redact it before sharing.

For foreground development after building, stop the installed service first and run this in one terminal:

```sh
"/Library/Application Support/Roomtastic/service.sh" stop
./build/Roomtastic.app/Contents/MacOS/RoomtasticService
```

Open `build/Roomtastic.app` in another terminal or Finder. Do not run a second service for the same user. A bounded diagnostic run can use `--run-for 30`; this starts the real service and may resume an existing Roomtastic setup, so it is not a dry run. When running a bare Swift build executable, set `ROOMTASTIC_SENDER_PATH` to the absolute path of `build/helpers/cliairplay`. Restore the installed service with `service.sh start` after the foreground service exits.

| Symptom | Check |
| --- | --- |
| Driver missing | Install the package and restart; opening the app alone does not install the driver. |
| Service unavailable | Use **Start Audio Service** in the menu or the service script; inspect terminal errors if running in the foreground. |
| No sound | Confirm routing is running, outputs are selected and available, mute is off, volume is audible, and the source app uses Roomtastic. Check microphone permission for virtual input capture. |
| Receiver absent | Check receiver power, shared network, local-network permission, and network isolation/firewall rules; run `--discover`. |
| Receiver preparing or failing | Read **Room Setup → Connection Details**. Check the shared clock service if requested and receiver authentication if challenged. |
| Calibration rejected | Check phone alignment, movement, noise, clipping, microphone route, and whether all selected outputs remained available. |
| Preset needs verification | Restore the measured speaker connections, room conditions, and levels, then measure again. Do not edit saved verification flags. |
| Xcode license/SDK error | Open full Xcode and finish its setup; confirm `DEVELOPER_DIR` points to that installation. |

State lives in `~/Library/Application Support/Roomtastic/state.json`; it includes room data, selections, profiles, and the previous output. The same directory contains the local control socket, service lock, phone peer metadata, and optional `Retained Recordings`. Stop the service before backing up or restoring this directory. Keychain credentials are separate and are not included in a directory backup. The phone keeps its scan, room alignment, and measurements in its own app storage.

Raw recordings are retained only when **Keep Recordings** is enabled. Use **Delete Saved Recordings** to remove retained measurements. Treat room geometry, recordings, and pairing information as private. The service definition does not configure persistent stdout/stderr log files; use foreground execution and the connection details for diagnosis.

## Deploy releases

### Mac installer

Before public binary distribution, resolve the permission questions recorded in [LICENSES/license-map.json](LICENSES/license-map.json), pass automated and hardware tests, and prepare Developer ID Application and Installer identities in Keychain. There is no automatic release upload or updater in this repository.

Keep version numbers consistent before building: `packaging/Info.plist`, the version assignments in `scripts/build-driver.sh`, and the package `VERSION`. Setting `VERSION` alone changes the installer and archive names, not those embedded app/driver versions.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPMENT_TEAM='YOUR_TEAM_ID'
export APPLICATION_IDENTITY='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)'
export INSTALLER_IDENTITY='Developer ID Installer: YOUR NAME (YOUR_TEAM_ID)'
export VERSION=1.0.0
# Create this Keychain profile beforehand using notarytool store-credentials.
export NOTARY_PROFILE='roomtastic-notary'
./scripts/build.sh
./scripts/package.sh
pkgutil --check-signature "dist/Roomtastic-$VERSION.pkg"
xcrun stapler validate "dist/Roomtastic-$VERSION.pkg"
```

The packaging script submits to Apple's notary service, waits, and attaches the resulting ticket when `NOTARY_PROFILE` is set. Omitting that variable skips notarization. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Test the resulting installer on a separate Mac, including upgrade, reboot, permissions, playback, and uninstall. Publish the matching installer and complete source archive together only after release checks pass. The source archive intentionally contains vendor Git metadata for revision verification; inspect it for local-only configuration or credentials before publication. The current archive script uses an explicit file list and does not yet include this README or AGENTS.md; distribute these documents alongside it.

For an upgrade, back up saved state, install the replacement package, and restart. The installer stops existing Roomtastic processes gracefully. Check and re-enable the optional timing service if necessary. There is no automatic saved-state downgrade migration; restoring an older release may require its matching state backup.

### iPhone companion

Use your own signing team and registered bundle identifier. Update the version/build in `iOS/RoomtasticPhone/Info.plist` as well as matching Xcode settings; the plist currently contains literal version values. Complete distribution assets and App Store Connect metadata before release.

Select a physical-device destination in Xcode, choose **Product → Archive**, then use Organizer to validate and distribute the archive to App Store Connect. After processing, configure TestFlight testing there. This repository does not automate that upload or provide signing credentials. Follow [Apple's distribution instructions](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases) and validate scanning and calibration on physical devices before inviting testers.

## Uninstall

```sh
sudo "/Library/Application Support/Roomtastic/uninstall.sh"
```

Restart macOS to unload the driver. The uninstaller stops Roomtastic processes, removes its app, driver, services, and package receipt, and preserves other audio drivers and user presets. It does not erase saved user state or Keychain credentials.

## Source layout and licensing

| Location | Responsibility |
| --- | --- |
| `Sources/RoomtasticMac` | Menu bar and setup interface |
| `Sources/RoomtasticService` | Device discovery, playback, phone measurement coordination |
| `Sources/RoomtasticControl` | Same-user local control socket |
| `Sources/RoomtasticDSP` | C++ audio buffers, filters, resampling, and clock tracking |
| `Sources/RoomtasticCalibration` | Measurement analysis, correction fitting, verification |
| `Sources/RoomtasticShared`, `Sources/RoomtasticTransport` | Shared models and encrypted phone communication |
| `iOS` | LiDAR, speaker placement, and microphone companion |
| `scripts`, `packaging`, `Vendor` | Builds, installation, and pinned dependencies |

### Licensing

The Mac application, audio processing, calibration, and build scripts use GPL-3.0-only. Shared models, phone transport, and iOS code use MIT where indicated. Vendor code retains its own notices. Consult [the license map](LICENSES/license-map.json) for file-level details.

The pinned AirPlay sender's notices flag unresolved upstream permission for `libraop/src/pairing.cpp` and `libraop/src/bplist.cpp`. This repository does not resolve those permissions. Public binary redistribution requires addressing them and providing corresponding source and notices.

For development rules and verification expectations, see [AGENTS.md](AGENTS.md).
