# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the Maneater crash/FPS repair setup and native recovery, navigation and loading optimizations from one window. **v0.7.0** includes ready-built binaries and their matching full sources.

The v0.7.0 algorithms passed gameplay testing on the reference Steam build. The tester reported that they worked great, and startup logs confirmed recovery, navigation, loading and FPS attachment. See [the validation record](docs/gameplay-validation.md).

## Download and run

1. [Download **Maneater-Crash-FPS-Fix.zip**](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Quit Maneater and double-click **Start.cmd**.
3. Wait for automatic detection, then click **Apply all fixes**. If the game is not found or there are multiple installations, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.
4. Click **Play Maneater** to start it through Steam.

The release ZIP includes the compiled mod DLL, its matching attachment helper, manifest, full sources and tests. Installing it requires no compiler or compiler download. A source-only checkout needs the developer build described below.

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

See [the release notes](docs/release-notes-0.7.0.md) for version history and validation details.

## Upgrade and restore

- **Update:** Extract the latest release into a **new folder**, run **Start.cmd**, and click **Apply all fixes**.
- **Restore:** Quit Maneater and click **Restore previous setup** in the launcher that applied the fixes.
- **Keep your backups:** Keep the old and new launcher folders, including `.local`.

If you reuse a launcher folder, restore with its old launcher before replacing its files. Restore preserves changes made by other tools.

## Why the CPU fix matters


Before the repair, the player reported frequent crashes during busy scenes. The OpenSSL launch workaround helped, but attacking groups of humans on land still caused heavy stuttering and short freezes. With the complete repair setup, repeated land-combat tests and a later longer play session were reported as generally smooth, with no crash. This is the result on the tested Intel PC; the CPU change alone was not shown to prevent every crash.

The game splits CPU work between background threads. More threads do not always mean faster play: too many competing for the same cores can add scheduling overhead and make the game wait before drawing its next frame. That can feel like an overloaded CPU even when Task Manager's overall CPU percentage is below 100%.

On the tested Intel hybrid CPU, simply keeping the game on its faster performance cores was not enough. Inspection showed that the engine still calculated a larger worker budget from the whole CPU. In one early affinity-only setup, it created **78 task-graph worker threads**; correcting the budget reduced that to **21**. These are background workers for engine tasks, not the game's total thread count.

The launcher therefore changes **both where the game runs and the core count it uses to size its workers**. The `-corelimit` option controls that calculation; it is not an exact count of every thread the game creates.

| CPU example | What the launcher does |
| --- | --- |
| Intel Core i9-13900K, as tested: 8 performance cores + 16 efficiency cores | Runs Maneater on the 8 performance cores, including their 16 logical threads, and sets `-corelimit=8`. The engine's budget then matches the physical performance cores selected for the game. |
| Another supported Intel hybrid CPU with 6 performance cores | Detects that CPU's actual core mapping, selects its performance cores and sets `-corelimit=6`. It does not copy the test PC's settings. |
| Ryzen with 6 physical cores / 12 logical threads | Sets `-corelimit=6`. All CPU threads remain available to Windows; no affinity mask is imposed. |
| Ryzen with 16 physical cores / 32 logical threads | Uses the same worker-budget approach with `-corelimit=16`, without pinning the game to one group of cores or disabling SMT. |

The Ryzen approach aims to reduce competition between workers sharing physical cores. It follows [AMD's guidance on choosing a starting thread-pool budget](https://gpuopen.com/learn/cpu-core-count-detection-windows/), but **has not been tested in Maneater gameplay on AMD hardware** and may improve or worsen performance. Unsupported or unclear CPU layouts keep their normal settings. These changes apply to Maneater's launch, preserve graphics quality, and can be reversed with **Restore previous setup**.


## Compatibility

Windows **10/11 x64**, Steam app **629820**. The reference is Steam build **7837297**, with shipping executable SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

The navigation and package-loading helper requires this full executable hash plus exact native code and caller guards. The get-up replacement instead checks the reference PE metadata, exact code, function identity and reflected field layout; it does not hash the whole executable. A different file hash that retains those checked values can still activate the getter. Such a build remains untested. A copied installation result does not prove any hook activated.

**Allow an untested build** remains preselected. Applying to a different executable hash still requires acceptance of its warning. Clear the option to restrict Apply to the reference build. The option does not weaken either the get-up metadata/code/layout checks or the navigation/loading full-hash checks. Navigation and loading therefore stay inactive on a different hash; get-up can attach only if its separate strict checks pass. The inherited FPS component may accept its own guarded opt-in checks, or remain inactive too. The other launch workarounds remain unverified on that build.

Detection and untested-build opt-in are limited to Maneater installations in the current Steam libraries; they do not establish support for Epic, Game Pass or another storefront. CPU plans are derived from Windows topology, with no developer-PC affinity mask, core count or GPU requirement copied into the launcher.

The compiled proxy's DXGI names and ordinals must match the local Windows library. Installation copies that verified Windows DLL from your PC; it is not distributed in the ZIP. Missing/corrupt package files or an incompatible export contract stop the repair before changing the setup.

## Results and limits

The combined v0.7.0 algorithms were tested during gameplay on the reference Steam build and one Intel PC. The tester reported that they worked great. Logs from that test confirmed the recovery getter, navigation and package-loading hooks attached, and the FPS correction redirected the matching request from 60 to 120.

Static-code review and offline tests cover forwarding, array ownership, conservative navigation decisions, x64 unwind behavior, installation, restoration and attachment rollback. Gameplay feedback supports the combined setup; it does not measure a percentage improvement or isolate the contribution of each patch. [Validation details](docs/gameplay-validation.md) record the tested binaries and scope.

The get-up replacement has a specific semantic uncertainty: the original chest-down wrapper was not fully recovered. Verified metadata and a readable sibling support the replacement, but unknown behavior could differ. The navigation index adds build/allocation cost and depends on stable geometry within its short scope; some searches can be slower. Removing the unused loading string changes allocation statistics and allocation-failure timing. The external attachment transaction retains a possible new-thread race after its last thread census.

Results vary by hardware and build. The release keeps graphics-quality settings intact; exact animation equivalence remains subject to the getter analysis limit above. Use **Restore previous setup** if the setup causes problems.

## Check startup status

The launcher reports file installation separately from runtime attachment. Startup logs beside `Maneater-Win64-Shipping.exe` provide the current launch's status:

- `maneater_codex_fps.log`: `INSTALLED` means the guarded FPS hook attached; `REDIRECTED` means a matching 60-to-120 request ran. `PASS-THROUGH` means its guard declined the change.
- `maneater_getup_fix.log`: `INSTALLED` means the one native getter pointer attached; `PASS-THROUGH` means the original stayed in use.
- `maneater_area_fix.log` and `maneater_area_attach_*.json`: describe navigation/package attachment or refusal. An uncertain attachment report must be treated as uncertain.

Read the latest launch's section, not a previous run. Attachment success verifies that a hook is present; it does not measure benefit or prove all gameplay calls use it.

## Development

Original project sources use the [MIT license](LICENSE); vendored trampoline/decoder components retain their licenses in [THIRD_PARTY.txt](THIRD_PARTY.txt). The ready-to-run ZIP includes matching full source, prebuilt DLL/helper and manifests. It contains no game binary, game asset, Windows DLL, save, private capture or compiler binary.

For a source build, obtain Zig and use 64-bit Windows PowerShell:

```powershell
.\build.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
.\tests\Run-All.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
```

The build creates the matching helper first and embeds its hash in the proxy. Keep the manifest and both binaries together. The tests use synthetic game/config data and inert fixture processes; they do not run Maneater or measure gameplay performance.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [the technical background](docs/crash-workarounds.md). The manager is for native file installation; use **Start.cmd** for the full repair and restoration workflow.
