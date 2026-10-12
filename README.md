# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the complete Maneater repair setup from one window. Pick the game executable, click **Apply all fixes**, then **Play Maneater**. **Restore previous setup** reverses the changes made by the launcher.

## Download and run

1. [Download the launcher ZIP](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Double-click **Start.cmd**.
3. Select **Maneater.exe** or **Maneater-Win64-Shipping.exe**, then click **Apply all fixes**.

The launcher detects your CPU, verifies the game build, builds the native mod, backs up the previous setup, and applies the fixes. No compiler commands or manual Steam launch-option edits are required. First use may download the pinned [Zig compiler](https://ziglang.org/download/) from ziglang.org (100 MB), with SHA-256 verification. Later runs reuse the local build and tool cache.

Quit Maneater first. The launcher asks to close Steam briefly to save its per-game settings; **Play Maneater** starts the game through Steam again. If Windows restricts access to the game folder, the launcher offers to restart with administrator access. Keep the extracted folder: its private `.local` directory contains your restore record and backups.

To update an existing setup, use the previous launcher's **Restore previous setup** first. Then replace the launcher source files with the new ZIP, retain `.local` and its backups, and apply again. An already applied repair is not automatically upgraded. A new launcher folder without the ownership records will preserve an existing, untracked mod DLL pair.

Version **0.3.0** also offers an explicit experimental opt-in for an untested Steam build. The tested-build check remains the default. See [Compatibility](#compatibility) before using that option.

## What Apply all fixes does

| Fix | Applied behavior |
| --- | --- |
| Native FPS correction | Replaces the supported engine's forced 60 FPS request with 120 FPS through its original setter. Other requests and graphics settings are preserved. |
| OpenSSL compatibility | Applies Maneater's official OpenSSL compatibility flag through game-specific Steam launch options. It does not set a permanent system environment variable. |
| CPU scheduling and worker budget | On a supported Intel hybrid topology, detects performance cores and derives both affinity and `-corelimit` from those cores. Homogeneous, AMD, ambiguous and multiple-processor-group layouts retain normal scheduling. |
| Ansel SDK | Reversibly disables the recognized bundled NVIDIA Ansel SDK. This removes its photo-mode support. Already absent or externally disabled copies are preserved. |
| Steam overlay | Turns off the overlay for Maneater only. |

Existing ordinary game arguments and recognized OpenSSL workaround wrappers are preserved or safely normalized. Arbitrary custom command wrappers and foreign DXGI mods are not overwritten. The untested-build opt-in does not authorize replacing an unknown Ansel SDK or bypassing file-ownership checks. The launcher saves a write-ahead restore record before changing files or settings and attempts rollback if an apply operation fails. Restore preserves files/settings changed by someone else.

These are the complete retained changes from the tested setup. They are not additional graphics reductions, save edits, executable patches or DRM bypasses. A native 60 FPS selection is also redirected to 120 FPS at the guarded caller in this release.

## Compatibility

Windows x64, Steam app **629820**. The tested reference is Steam build **7837297**, with shipping executable SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

The executable hash identifies the tested build. You can preview another Windows x64 build, but applying fixes to a different hash is refused by default. To try another Steam build, enable **Allow an untested build (experimental)** and accept its warning for that apply operation. Each apply requires acceptance; a previous acceptance is not a claim that the new build is supported.

This option is limited to an installation identified as Maneater in the current Steam libraries. It does not implicitly support Epic, Game Pass, other storefronts, or an arbitrary executable copied elsewhere. The actual selected executable hash is recorded in the private repair journal.

Opting in permits an experiment; it does not establish compatibility. It can relax the native version-metadata check, while keeping exact code signatures, image bounds, object layout and call-site guards. The FPS hook may decline to change anything if the game differs. An unrecognized Ansel SDK is preserved, that step is skipped, and the launcher reports a warning. The retained workarounds and their benefits also remain unverified on that build. Use **Restore previous setup** if the experiment does not help.

CPU settings are derived from Windows topology, with no preset mask or core count copied from a developer's PC. The bundle does not impose a particular GPU model.

### Installed files versus an applied FPS correction

An installation result means the launcher copied the mod files and recorded the setup. The native FPS row therefore says **Installed**, rather than claiming the FPS correction ran. It does not prove that the game loaded the hook or that its runtime checks accepted this build. After **Play Maneater**, check the latest launch's section of `maneater_codex_fps.log` in the game's `Maneater/Binaries/Win64` directory; an entry from a previous launch does not confirm the current one.

The native log's `INSTALLED` entry means the guarded hook attached; `REDIRECTED` verifies that a matching game request was forwarded from 60 to 120. `PASS-THROUGH` means the native guard declined the correction. A successful redirect does not guarantee 120 rendered frames per second: game workload, display settings and other limits still affect performance. An untested build remains experimental even if it redirects.

## Results and limits

The retained setup, using the earlier native FPS v0.1 core on the tested build, was checked in repeated land-combat sessions and a longer play session reported as generally smooth with no crash. The FPS redirect and reduced hybrid-CPU worker budget were independently verified during gameplay. Resource, frame and engine-tick captures were reviewed; one brief CPU hitch remained in a short capture, and loading/focus changes caused other gaps.

Native v0.2 adds experimental-build and mapped-image guards. Those additions were checked through contract fixtures and source review; the updated DLL has not undergone a new gameplay test. The earlier gameplay results do not establish that this entire new DLL or another game build works.

The gameplay tests cover the tested executable on one hardware configuration. They do not validate other builds, prove that any one change prevents all crashes, or show that every machine benefits equally. The native DLL's verified behavior is the guarded FPS correction. The OpenSSL mitigation is documented by [Maneater support](https://support.maneatergame.com/en/knowledgebase/article/cant-launch-game-black-screen) and [Intel](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/openssl-sha-crash-bug-requires-application-update.html). Ansel and overlay changes are reversible retained mitigations, without isolated causal proof.

## Development

All launcher and native sources are included under the [MIT license](LICENSE). No game or Windows DLL, save, private trace, or compiler binary is distributed. The launcher builds its DXGI forwarder from the current local Windows export contract and installs an unchanged, verified local Windows DXGI copy beside it. Existing proxy files belonging to other mods are preserved.

For a manual build, use 64-bit Windows PowerShell:

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

Run the isolated fixture suite with `tests\Run-All.ps1`. These tests use temporary game/config fixtures; they do not modify a real installation. Native contract tests cover guard rejection and forwarding. Actual matching-caller behavior was separately verified during gameplay with the earlier tested-build FPS core, not the new experimental-build path.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reports and development rules, and [the technical background](docs/crash-workarounds.md) for individual changes. This is an unofficial community project; the license covers this project's original source, not third-party software.
