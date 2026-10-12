# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the complete Maneater repair setup from one window. It finds the game automatically; click **Apply all fixes**, then **Play Maneater**. **Restore previous setup** reverses the changes made by the launcher.

## Download and run

1. [Download the ready-to-run launcher ZIP](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Double-click **Start.cmd**.
3. Wait for automatic detection, then click **Apply all fixes**. If the game is not found or there are multiple installations, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.

The ready-to-run release ZIP includes the compiled project mod and its matching full sources. No compiler or compiler download is required. The launcher searches Steam's installation folders and registered libraries, including libraries on other drives and custom folders recorded in the game manifest. It validates the included mod, detects your CPU, verifies the game build, backs up the previous setup, and applies the fixes. Manual Steam launch-option edits are not required.

Choose the release asset named **Maneater-Crash-FPS-Fix.zip**. GitHub's automatic **Source code (zip/tar.gz)** downloads and repository clones are developer sources and require a manual build; the launcher does not compile or download a compiler for them.

Quit Maneater first. The launcher asks to close Steam briefly to save its per-game settings; **Play Maneater** starts the game through Steam again. If Windows restricts access to the game folder, the launcher offers to restart with administrator access. Keep the extracted folder: its private `.local` directory contains your restore record and backups.

To update an existing setup, use the previous launcher's **Restore previous setup** first. Then replace all launcher files, including `dist`, with the new ready-to-run ZIP, retain `.local` and its backups, and apply again. An already applied repair is not automatically upgraded. A new launcher folder without the ownership records will preserve an existing, untracked mod DLL pair.

**Allow an untested build (experimental)** is preselected. You can clear it to restrict Apply to the tested build. An untested build still requires acceptance of its warning before changes are made. See [Compatibility](#compatibility).

## What Apply all fixes does

| Fix | Applied behavior |
| --- | --- |
| Native FPS correction | Replaces the supported engine's forced 60 FPS request with 120 FPS through its original setter. Other requests and graphics settings are preserved. |
| OpenSSL compatibility | Applies Maneater's official OpenSSL compatibility flag through game-specific Steam launch options. It does not set a permanent system environment variable. |
| CPU scheduling and worker budget | Matches the game's CPU worker budget to the detected hardware. On supported Intel hybrid CPUs, it also keeps the game on performance cores. Eligible Ryzen CPUs get an experimental worker limit with normal Windows scheduling. See [the explanation and examples below](#why-the-cpu-fix-matters). |
| Ansel SDK | Reversibly disables the recognized bundled NVIDIA Ansel SDK. This removes its photo-mode support. Already absent or externally disabled copies are preserved. |
| Steam overlay | Turns off the overlay for Maneater only. |

Existing ordinary game arguments and recognized OpenSSL workaround wrappers are preserved or safely normalized. Arbitrary custom command wrappers and foreign DXGI mods are not overwritten. The untested-build opt-in does not authorize replacing an unknown Ansel SDK or bypassing file-ownership checks. The launcher saves a write-ahead restore record before changing files or settings and attempts rollback if an apply operation fails. Restore preserves files/settings changed by someone else.

These are the complete retained changes from the tested setup. They are not additional graphics reductions, save edits, executable patches or DRM bypasses. A native 60 FPS selection is also redirected to 120 FPS at the guarded caller in this release.

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

Windows **10/11 x64**, Steam app **629820**. The compiled mod uses the Universal C Runtime [included with these Windows versions](https://learn.microsoft.com/en-us/cpp/windows/universal-crt-deployment?view=msvc-170). The tested reference is Steam build **7837297**, with shipping executable SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

The executable hash identifies the tested build. The GUI preselects **Allow an untested build (experimental)**, but applying to a different hash still requires acceptance of its warning for that operation. Clear the option to allow only the tested build. A previous acceptance is not a claim that another build is supported. The command-line manager and repair backend continue to require an explicit untested-build flag.

This option is limited to an installation identified as Maneater in the current Steam libraries. It does not implicitly support Epic, Game Pass, other storefronts, or an arbitrary executable copied elsewhere. The actual selected executable hash is recorded in the private repair journal.

Opting in permits an experiment; it does not establish compatibility. It can relax the native version-metadata check, while keeping exact code signatures, image bounds, object layout and call-site guards. The FPS hook may decline to change anything if the game differs. An unrecognized Ansel SDK is preserved, that step is skipped, and the launcher reports a warning. The retained workarounds and their benefits also remain unverified on that build. Use **Restore previous setup** if the experiment does not help.

CPU settings are derived from Windows topology, with no preset mask or core count copied from a developer's PC. The bundle does not impose a particular GPU model.

The experimental Ryzen worker limit requires a recognized AMD Ryzen CPU with SMT and a validated single processor group. Older or unidentified AMD CPUs, CPUs without SMT, and multiple processor groups are excluded. It leaves X3D/CCD placement to Windows and the chipset drivers. See [the CPU examples and testing limits above](#why-the-cpu-fix-matters).

The included mod also requires a matching Windows DXGI export contract: exported names and ordinals must agree with the verified local Windows library. That Windows DLL is copied from your PC during installation, not distributed in the ZIP. A different local Windows DLL file hash alone is acceptable when the export contract matches. Missing, stale or corrupt packaged files, or an incompatible export contract, stop the repair before it changes game files or Steam settings. There is no automatic compilation fallback; download a compatible ready release or use the developer build instructions below.

### Installed files versus an applied FPS correction

An installation result means the launcher copied the mod files and recorded the setup. The native FPS row therefore says **Installed**, rather than claiming the FPS correction ran. It does not prove that the game loaded the hook or that its runtime checks accepted this build. After **Play Maneater**, check the latest launch's section of `maneater_codex_fps.log` in the game's `Maneater/Binaries/Win64` directory; an entry from a previous launch does not confirm the current one.

The native log's `INSTALLED` entry means the guarded hook attached; `REDIRECTED` verifies that a matching game request was forwarded from 60 to 120. `PASS-THROUGH` means the native guard declined the correction. A successful redirect does not guarantee 120 rendered frames per second: game workload, display settings and other limits still affect performance. An untested build remains experimental even if it redirects.

## Results and limits

Gameplay tests of the repair approach showed smoother land combat and a longer play session without a crash. The current package is checked through automated tests and source review, covering installation, restoration, DLL forwarding and native compatibility guards. Occasional gameplay and loading hitches can still occur.

Results vary by hardware and game build. Gameplay testing covers one configuration, so the mod does not guarantee a crash-free experience or identical improvements on every PC. The FPS correction activates only when its runtime checks pass. The OpenSSL workaround is documented by [Maneater support](https://support.maneatergame.com/en/knowledgebase/article/cant-launch-game-black-screen) and [Intel](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/openssl-sha-crash-bug-requires-application-update.html); the Ansel and overlay changes remain reversible mitigations.

## Development

The Git repository and GitHub's automatic source archives contain sources under the [MIT license](LICENSE). The custom ready-to-run release ZIP also includes the compiled project DXGI forwarder, its build manifest and export definition, and matching sources. No game or Windows DLL, save, private trace, or compiler binary is distributed. Installation copies an unchanged, verified local Windows DXGI DLL beside the project mod. Existing proxy files belonging to other mods are preserved.

For a developer build from a clone or source archive, obtain [Zig](https://ziglang.org/download/) and use 64-bit Windows PowerShell. The build generates a forwarder for the current local Windows export contract:

```powershell
.\build.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
```

The separate native manager remains available to contributors:

```powershell
.\Manage-Mod.ps1 -Action Install -GameDirectory 'D:\SteamLibrary\steamapps\common\Maneater'
.\Manage-Mod.ps1 -Action Status
.\Manage-Mod.ps1 -Action Uninstall
```

The native manager handles only its DLL pair. Normal users should use **Start.cmd** for the complete repair and restore.

For advanced manual installation, add `-AllowUntestedBuild` to the manager's `-Action Install` command. That authorizes installation on an untested executable; it does not enable the native runtime opt-in or configure Steam. The game's own process must receive the exact environment value `MANEATER_FIX_ALLOW_UNTESTED=1` to permit experimental native metadata checks. Keep that assignment scoped to the game launch. The GUI configures it automatically for an accepted untested-build trial and sets it to `0` for the tested build.

Run the isolated developer fixture suite with `tests\Run-All.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'`. These tests use temporary game/config fixtures; they do not modify a real installation. Native contract tests cover guard rejection and forwarding. Actual matching-caller behavior was separately verified during gameplay with the earlier tested-build FPS core, not the new experimental-build path.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reports and development rules, and [the technical background](docs/crash-workarounds.md) for individual changes. This is an unofficial community project; the license covers this project's original source, not third-party software.
