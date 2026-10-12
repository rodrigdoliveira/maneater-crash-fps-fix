# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the Maneater crash/FPS repair setup and native recovery, navigation and loading optimizations from one window. **v0.8.0** includes ready-built binaries and their matching full sources.

The game optimizations passed gameplay testing on the reference Steam build. The tester reported that they worked great, and startup logs confirmed recovery, navigation, loading and FPS attachment. See [the validation record](docs/gameplay-validation.md).

## Download and run

1. [Download **Maneater-Crash-FPS-Fix.zip**](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Double-click **Start.cmd**. The updater checks GitHub, installs any newer launcher package, then opens the launcher. Quit Maneater before applying game fixes.
3. Wait for automatic detection, then click **Apply all fixes**. If the game is not found or there are multiple installations, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.
4. Click **Play Maneater** to start it through Steam.

The release ZIP includes the compiled mod DLL, its matching attachment helper, manifest, full sources and tests. Extract the ZIP once for the first installation. Future launcher updates are automatic; no compiler or compiler download is required. A source-only checkout needs the developer build described below.

The launcher searches Steam's installation folders and registered libraries, including other drives and custom folders recorded in the game manifest. It detects your CPU and validates the game, packaged binaries and local Windows DXGI export contract before applying changes. Manual Steam launch-option edits are not required.

The launcher may ask to close Steam briefly to save its per-game settings. If Windows restricts access to the game folder, it offers to restart with administrator access. Keep the extracted folder: `.local` contains the restore record and backups. Do not run two mod installers at the same time.

## What Apply all fixes does

Applies the following fixes and optimizations with compatibility checks and backups:

| Fix | Applied behavior |
| --- | --- |
| Native FPS correction | Redirects the guarded engine's 60 FPS request to 120 through its original setter. Other requests and graphics-quality settings are preserved. This does not guarantee 120 rendered frames per second. |
| Human recovery animation | Streamlines one get-up animation lookup using the game's original animation selector and random-selection behavior. |
| Navigation | Avoids unnecessary searches when connecting navigation data during area loading. Possible connections still use the game's original finder. |
| Package loading | Removes unused temporary package-name string work while preserving the original loader's inputs and loading order. |
| OpenSSL compatibility | Applies the existing OpenSSL compatibility flag through game-specific Steam launch options. |
| CPU scheduling and worker budget | Uses detected hardware to choose the worker budget. Supported Intel hybrid CPUs also use performance-core affinity; eligible Ryzen SMT CPUs get a physical-core budget without an affinity mask. |
| Ansel SDK | Reversibly disables the recognized bundled NVIDIA Ansel SDK, removing its photo-mode support. Unknown or already absent/disabled copies are preserved. |
| Steam overlay | Turns off the overlay for Maneater only. |

The setup preserves graphics-quality settings and saves. Native optimizations activate only when their compatibility checks pass. Damage and collision events retain their original handling, and the stock executable and game archives are not edited on disk.

A matching **ManeaterAreaHelper.exe** starts hidden during game startup, verifies the target and attaches the native entries, then exits. It is an attachment helper, not a gameplay profiler. The DLL/helper pair is verified together and included in the ZIP.

See [the release notes](docs/release-notes-0.8.0.md) for version history and validation details.

## Upgrade and restore

- **Update:** Run **Start.cmd**. The separate updater checks GitHub, downloads and verifies the latest package, then opens the launcher.
- **Update game fixes:** If prompted, quit Maneater and click **Apply all fixes**. Your original restore backups are retained.
- **Restore:** Click **Restore previous setup** in the launcher that applied the fixes.

Keep the launcher folder and `.local` backups. Interrupted updates roll back; changed or untracked files are preserved. If the update check cannot finish, you can open the installed version.

## Why the CPU fix matters

Too many background workers can make Maneater stutter during busy combat. In the Intel test, selecting performance cores alone still left **78 engine task workers**; correcting the worker budget reduced that to **21**.

The launcher detects your CPU and adjusts the budget automatically. Supported Intel hybrid CPUs use performance cores; eligible Ryzen CPUs use a physical-core budget with normal Windows scheduling. Graphics quality stays unchanged.

## Compatibility

- **Platform:** Windows 10/11 x64, Steam edition of Maneater.
- **Tested game build:** Steam build **7837297**.
- **Tested hardware:** Intel Core **i9-13900K** with NVIDIA GeForce **RTX 4070**.
- **AMD Ryzen:** CPU support is included, but has not been gameplay-tested on AMD hardware.

You can try other builds with **Allow an untested build**, which is preselected. The launcher shows a warning, and fixes that fail their compatibility checks stay inactive. Epic and Game Pass versions have not been tested.

## Development

Original project sources use the [MIT license](LICENSE); vendored trampoline/decoder components retain their licenses in [THIRD_PARTY.txt](THIRD_PARTY.txt). The ready-to-run ZIP includes matching full source, prebuilt DLL/helper and manifests. It contains no game binary, game asset, Windows DLL, save, private capture or compiler binary.

For a source build, obtain Zig and use 64-bit Windows PowerShell:

```powershell
.\build.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
.\tests\Run-All.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
```

The build creates the matching helper first and embeds its hash in the proxy. Keep the manifest and both binaries together. The tests use synthetic game/config data and inert fixture processes; they do not run Maneater or measure gameplay performance.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [the technical background](docs/crash-workarounds.md). The manager is for native file installation; use **Start.cmd** for the full repair and restoration workflow.
