# Maneater Crash & FPS Fix

A free, open-source Windows launcher that applies the complete Maneater repair setup from one window. Pick the game executable, click **Apply all fixes**, then **Play Maneater**. **Restore previous setup** reverses the changes made by the launcher.

## Download and run

1. [Download the launcher ZIP](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/releases/latest/download/Maneater-Crash-FPS-Fix.zip) and extract it into a folder you will keep.
2. Double-click **Start.cmd**.
3. Select **Maneater.exe** or **Maneater-Win64-Shipping.exe**, then click **Apply all fixes**.

The launcher detects your CPU, verifies the game build, builds the native mod, backs up the previous setup, and applies the fixes. No compiler commands or manual Steam launch-option edits are required. First use may download the pinned [Zig compiler](https://ziglang.org/download/) from ziglang.org (100 MB), with SHA-256 verification. Later runs reuse the local build and tool cache.

Quit Maneater first. The launcher asks to close Steam briefly to save its per-game settings; **Play Maneater** starts the game through Steam again. If Windows restricts access to the game folder, the launcher offers to restart with administrator access. Keep the extracted folder: its private `.local` directory contains your restore record and backups.

## What Apply all fixes does

| Fix | Applied behavior |
| --- | --- |
| Native FPS correction | Replaces the supported engine's forced 60 FPS request with 120 FPS through its original setter. Other requests and graphics settings are preserved. |
| OpenSSL compatibility | Applies Maneater's official OpenSSL compatibility flag through game-specific Steam launch options. It does not set a permanent system environment variable. |
| CPU scheduling and worker budget | On a supported Intel hybrid topology, detects performance cores and derives both affinity and `-corelimit` from those cores. Homogeneous, AMD, ambiguous and multiple-processor-group layouts retain normal scheduling. |
| Ansel SDK | Reversibly disables the recognized bundled NVIDIA Ansel SDK. This removes its photo-mode support. Already absent or externally disabled copies are preserved. |
| Steam overlay | Turns off the overlay for Maneater only. |

Existing ordinary game arguments and recognized OpenSSL workaround wrappers are preserved or safely normalized. An arbitrary custom command wrapper, unsupported game build, unknown Ansel DLL or foreign DXGI mod produces an actionable error instead of an overwrite. The launcher saves a write-ahead restore record before changing files or settings and attempts rollback if an apply operation fails. Restore preserves files/settings changed by someone else.

These are the complete retained changes from the tested setup. They are not additional graphics reductions, save edits, executable patches or DRM bypasses. A native 60 FPS selection is also redirected to 120 FPS at the guarded caller in this release.

## Compatibility

Windows x64, Steam app **629820**. The current native mod supports Steam build **7837297**, with shipping executable SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

The executable hash is authoritative. Other storefronts and game builds require separate validation. CPU settings are derived from Windows topology, with no preset mask or core count copied from a developer's PC. The bundle does not impose a particular GPU model.

## Results and limits

The complete setup was tested in repeated land-combat sessions, followed by a longer play session reported as generally smooth with no crash. The FPS redirect and reduced hybrid-CPU worker budget were independently verified during gameplay. Resource, frame and engine-tick captures were reviewed; one brief CPU hitch remained in a short capture, and loading/focus changes caused other gaps.

The tests cover one hardware configuration. They do not prove that any one change prevents all crashes, or that every machine benefits equally. The native DLL's verified behavior is the guarded FPS correction. The OpenSSL mitigation is documented by [Maneater support](https://support.maneatergame.com/en/knowledgebase/article/cant-launch-game-black-screen) and [Intel](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/openssl-sha-crash-bug-requires-application-update.html). Ansel and overlay changes are reversible retained mitigations, without isolated causal proof.

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

Run the isolated fixture suite with `tests\Run-All.ps1`. These tests use temporary game/config fixtures; they do not modify a real installation. Native contract tests cover guard rejection and forwarding, with actual matching-caller behavior separately verified during gameplay.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reports and development rules, and [the technical background](docs/crash-workarounds.md) for individual changes. This is an unofficial community project; the license covers this project's original source, not third-party software.
