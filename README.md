# Maneater Crash & FPS Fix

**Local preview 0.7.0-preview.1.** A free, open-source Windows launcher that applies the existing repair setup and three experimental native optimizations from one window. This preview includes ready-built binaries and their matching full sources. It is a local package; no new GitHub release is required.

The current private build already contains the same get-up, navigation and package-loading algorithms. This preview brings them into the normal launcher, upgrade and restore workflow; repackaging them does not establish a new performance improvement.

## Run the local preview

1. Extract the supplied **local ready-to-run preview ZIP** into a folder you will keep.
2. Quit Maneater and double-click **Start.cmd**.
3. Wait for automatic detection, then click **Apply all fixes**. If the game is not found or there are multiple installations, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.
4. Click **Play Maneater** to start it through Steam.

The release ZIP includes the compiled mod DLL, its matching attachment helper, manifest, full sources and tests. Installing it requires no compiler or compiler download. A source-only checkout needs the developer build described below.

The launcher searches Steam's installation folders and registered libraries, including other drives and custom folders recorded in the game manifest. It detects your CPU and validates the game, packaged binaries and local Windows DXGI export contract before applying changes. Manual Steam launch-option edits are not required.

The launcher may ask to close Steam briefly to save its per-game settings. If Windows restricts access to the game folder, it offers to restart with administrator access. Keep the extracted folder: `.local` contains the restore record and backups. Do not run two mod installers at the same time.

## What Apply all fixes does

The established v0.6.0 repair setup is retained:

| Fix | Applied behavior |
| --- | --- |
| Native FPS correction | Redirects the guarded engine's 60 FPS request to 120 through its original setter. Other requests and graphics-quality settings are preserved. This does not guarantee 120 rendered frames per second. |
| OpenSSL compatibility | Applies the existing OpenSSL compatibility flag through game-specific Steam launch options. |
| CPU scheduling and worker budget | Uses detected hardware to choose the worker budget. Supported Intel hybrid CPUs also use performance-core affinity; eligible Ryzen SMT CPUs get an experimental physical-core budget without an affinity mask. |
| Ansel SDK | Reversibly disables the recognized bundled NVIDIA Ansel SDK, removing its photo-mode support. Unknown or already absent/disabled copies are preserved. |
| Steam overlay | Turns off the overlay for Maneater only. |

The preview adds these exact-build experimental changes:

| Optimization | What it changes |
| --- | --- |
| Human get-up animation lookup | Replaces one native lookup for an uninjured human's chest-down get-up animation. It copies the corresponding animation list and uses the game's original selector, retaining null filtering, random draws and the four existing getter calls' order. |
| Navigation connection searches | Builds a temporary boundary-edge index during eligible area-loading calls. It returns no match early only when the original plane/overlap tests cannot succeed; possible matches still run the original finder. Direction buckets make repeated lookups cheaper. |
| Package-loading label | Removes construction and disposal of an unused `Package ` + name string. The same inner loader receives the same original inputs, flags and return contract. |

Damage and collision events are not suppressed. Navigation and asset work are not moved to another frame. The stock executable and game archives are not edited on disk. The navigation and package-loading changes use guarded native entry hooks in process memory, in addition to the inherited FPS object hook and get-up function-pointer replacement.

A matching **ManeaterAreaHelper.exe** starts hidden during game startup, verifies the target and attaches the native entries, then exits. It is an attachment helper, not a gameplay profiler. The DLL/helper pair is verified together and included in the ZIP.

## What changed from v0.6.0

v0.6.0 already included the 120 FPS correction, Intel and experimental Ryzen CPU plans, OpenSSL flag, Ansel/overlay changes, game detection, backup/restore and the preselected untested-build option. Those are not new in this preview.

The three rows above are the additions. Navigation's earlier private V1 and the included V2 are stages of one optimization: V2 groups the same temporary index by direction and retains V1's conservative rejection conditions. There are not two separate navigation fixes.

The failed recovery-event asset guard and later speculative queue, persistent-cache, get-up compaction and string-search experiments are not included. See [the preview release notes](docs/release-notes-0.7.0-preview.1.md) for the comparison and evidence limits.

## Upgrade and restore

For an upgrade, extract the preview into a **new folder** and run its launcher. The new folder can recognize and back up the reviewed v0.6.0 and latest private native files already beside the game. Keep the earlier launcher folder and its recovery records too. If you reuse a folder with an already applied repair journal, first use that folder's old launcher to **Restore previous setup**, then replace its package files and apply the preview. An existing applied journal is not an automatic upgrade.

**Apply all fixes** recognizes the reviewed public native v0.2 pair used by v0.6.0 and the known private predecessor pairs. It backs up the recognized previous files and records the complete installed tuple, including whether a helper existed. Unknown DLLs/helpers or conflicting ownership records are preserved by refusing replacement.

**Restore previous setup** restores the complete previous owned setup from that record, including the previous DLL/helper tuple and launcher-managed settings. If another tool has changed a tracked file or setting, restore preserves that change instead of blindly overwriting it. Backups and ownership records are part of the installation; keep them with the launcher.

Existing ordinary game arguments and recognized OpenSSL wrappers are preserved or safely normalized. Arbitrary custom launch wrappers and foreign DXGI mods are not overwritten. File replacements are atomic individually, but several files/settings are coordinated through the recovery record rather than one filesystem transaction.

## Why the CPU fix matters


Before the repair, the player reported frequent crashes during busy scenes. The OpenSSL launch workaround helped, but attacking groups of humans on land still caused heavy stuttering and short freezes. With the complete repair setup, repeated land-combat tests and a later longer play session were reported as generally smooth, with no crash. This is the result on the tested Intel PC; the CPU change alone was not shown to prevent every crash.

The game splits CPU work between background threads. More threads do not always mean faster play: too many competing for the same cores can add scheduling overhead and make the game wait before drawing its next frame. That can feel like an overloaded CPU even when Task Manager's overall CPU percentage is below 100%.

On the tested Intel hybrid CPU, simply keeping the game on its faster performance cores was not enough. Inspection showed that the engine still calculated a larger worker budget from the whole CPU. In one early affinity-only setup, it created **78 task-graph worker threads**; correcting the budget reduced that to **21**. These are background workers for engine tasks, not the game's total thread count.

The launcher therefore changes **both where the game runs and the core count it uses to size its workers**. The `-corelimit` option controls that calculation; it is not an exact count of every thread the game creates.

| CPU example | What the launcher does |
| --- | --- |
| Intel Core i9-13900K, as tested: 8 performance cores + 16 efficiency cores | Runs Maneater on the 8 performance cores, including their 16 logical threads, and sets `-corelimit=8`. The engine's budget then matches the physical performance cores selected for the game. |
| Another supported Intel hybrid CPU with 6 performance cores | Detects that CPU's actual core mapping, selects its performance cores and sets `-corelimit=6`. It does not copy the test PC's settings. |
| Ryzen with 6 physical cores / 12 logical threads | Experimentally sets `-corelimit=6`. All CPU threads remain available to Windows; no affinity mask is imposed. |
| Ryzen with 16 physical cores / 32 logical threads | Uses the same experimental approach with `-corelimit=16`, without pinning the game to one group of cores or disabling SMT. |

The Ryzen approach aims to reduce competition between workers sharing physical cores. It follows [AMD's guidance on choosing a starting thread-pool budget](https://gpuopen.com/learn/cpu-core-count-detection-windows/), but **has not been tested in Maneater gameplay on AMD hardware** and may improve or worsen performance. Unsupported or unclear CPU layouts keep their normal settings. These changes apply to Maneater's launch, preserve graphics quality, and can be reversed with **Restore previous setup**.


## Compatibility

Windows **10/11 x64**, Steam app **629820**. The reference is Steam build **7837297**, with shipping executable SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

The navigation and package-loading helper requires this full executable hash plus exact native code and caller guards. The get-up replacement instead checks the reference PE metadata, exact code, function identity and reflected field layout; it does not hash the whole executable. A different file hash that retains those checked values can still activate the getter. Such a build remains untested. A copied installation result does not prove any hook activated.

**Allow an untested build (experimental)** remains preselected. Applying to a different executable hash still requires acceptance of its warning. Clear the option to restrict Apply to the reference build. The option does not weaken either the get-up metadata/code/layout checks or the navigation/loading full-hash checks. Navigation and loading therefore stay inactive on a different hash; get-up can attach only if its separate strict checks pass. The inherited FPS component may accept its own narrow experimental checks, or remain inactive too. The other launch workarounds remain unverified on that build.

Detection and untested-build opt-in are limited to Maneater installations in the current Steam libraries; they do not establish support for Epic, Game Pass or another storefront. CPU plans are derived from Windows topology, with no developer-PC affinity mask, core count or GPU requirement copied into the launcher.

The compiled proxy's DXGI names and ordinals must match the local Windows library. Installation copies that verified Windows DLL from your PC; it is not distributed in the ZIP. Missing/corrupt package files or an incompatible export contract stop the repair before changing the setup.

## Results and limits

The earlier repair approach had sessions reported as smoother and crash-free on one Intel PC, but later combat and loading hitches remained. Those sessions do not validate the new native optimizations or prove that an individual workaround prevents crashes.

The added changes have static-code review and offline tests for forwarding, array ownership, conservative navigation decisions, x64 unwind behavior, installation, restoration and attachment rollback. The current combined algorithms have no verified gameplay benefit or real-game attachment result in the reviewed build manifest. Synthetic timing gains are not FPS or loading-time measurements.

The get-up replacement has a specific semantic uncertainty: the original chest-down wrapper was not fully recovered. Verified metadata and a readable sibling support the replacement, but unknown behavior could differ. The navigation index adds build/allocation cost and depends on stable geometry within its short scope; some searches can be slower. Removing the unused loading string changes allocation statistics and allocation-failure timing. The external attachment transaction retains a possible new-thread race after its last thread census.

This is an experimental preview, not a guarantee of crash-free play, eliminated stutters or identical improvements on every machine. It retains current visuals as its design goal; the unresolved get-up equivalence limits mean exact animation behavior has not been proved. Use **Restore previous setup** if it causes problems.

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
