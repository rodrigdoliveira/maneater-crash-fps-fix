![Maneater Crash & FPS Fix](docs/assets/banner.png)

# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the Maneater crash/FPS repair setup and native recovery, navigation and loading optimizations from one window. **v0.9.0** includes ready-built binaries and their matching full sources.

The game optimizations passed gameplay testing on the reference Steam build. The latest fix removes costly memory checks that could stall the game while preparing new areas, with the same improvement applied to human recovery animations. See [the validation record](docs/gameplay-validation.md).

## Download and run

1. [Download **Maneater-Crash-FPS-Fix.zip**](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Double-click **Start.cmd**. The updater checks GitHub, installs any newer launcher package, then opens the launcher. Quit Maneater before applying game fixes.
3. Wait for automatic detection, then click **Apply all fixes**. If the game is not found or there are multiple installations, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.
4. Click **Play Maneater** to start it through Steam.

The release ZIP includes the compiled mod DLL, its matching attachment helper, manifest, full sources and tests. Extract the ZIP once for the first installation. Future launcher updates are automatic; no compiler or compiler download is required. A source-only checkout needs the developer build described below.

The launcher searches Steam's installation folders and registered libraries, including other drives and custom folders recorded in the game manifest. It detects your CPU and validates the game, packaged binaries and local Windows DXGI export contract before applying changes. Manual Steam launch-option edits are not required.

The launcher may ask to close Steam briefly to save its per-game settings. If Windows restricts access to the game folder, it offers to restart with administrator access. Keep the extracted folder: `.local` contains the restore record and backups. Do not run two mod installers at the same time.

## What Apply all fixes does

One click applies these fixes, with backups so you can undo the changes:

| Fix | What it does |
| --- | --- |
| Higher FPS | Raises the game's forced 60 FPS limit to 120 FPS. Your actual FPS still depends on your PC. |
| Humans getting back up | Cuts unnecessary work when choosing how knocked-down humans get back up during combat. |
| Preparing new areas | Reduces unnecessary work when preparing paths for characters in newly loaded areas. |
| Loading game files | Removes unnecessary work while loading game data, without changing what gets loaded. |
| Startup crashes and black screen | Addresses a known startup problem that can cause a crash or black screen on affected Intel PCs. |
| CPU stuttering | Matches the game's background workload to your CPU to help reduce stuttering in busy scenes. Supports eligible Intel and Ryzen processors. |
| NVIDIA photo mode | Disables NVIDIA Ansel as a stability precaution. Its photo mode will be unavailable while the fix is applied. |
| Steam overlay | Turns off Steam's Shift+Tab overlay for Maneater to reduce possible conflicts. |

Your graphics settings, saves and combat rules stay unchanged. Each fix checks compatibility before turning on, and **Restore previous setup** can undo the changes.

The included helper runs briefly when Maneater starts to activate compatible fixes, then closes automatically.

See [the release notes](docs/release-notes-0.9.0.md) for version history and validation details.

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
