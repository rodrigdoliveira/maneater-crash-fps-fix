# Maneater Crash & FPS Fix

An open-source Windows mod and troubleshooting notes for **Maneater**. The implemented native change corrects a 60 FPS cap in the supported Steam build: when the verified engine call requests 60 FPS, the mod passes 120 FPS to the original setter instead. Crash-free testing is documented below; it does not establish that this DLL prevents crashes.

The correction preserves the setter's flags and callbacks. Other requests pass through. Graphics settings and saved games are unchanged.

Source repository: [rodrigdoliveira/maneater-crash-fps-fix](https://github.com/rodrigdoliveira/maneater-crash-fps-fix).

## Compatibility

The current implementation supports this Windows x64 Steam executable:

| Item | Supported value |
| --- | --- |
| Steam build | `7837297` |
| Executable | `Maneater-Win64-Shipping.exe` |
| SHA-256 | `CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0` |

The executable hash is authoritative. Other storefronts or executable versions need separate validation. The installer rejects unsupported executables, and the hook checks the engine code, console-variable object and call site before changing dispatch.

These checks identify a game build; they impose no particular CPU or GPU model. Runtime testing so far covers one configuration, not every Windows or hardware combination.

## Build from source

This repository distributes source, not prebuilt binaries. Use 64-bit Windows PowerShell 5.1 or later and a locally installed [Zig compiler](https://ziglang.org/download/).

From the repository directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Zig is resolved from `PATH`. To select it explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -ZigPath 'D:\Tools\Zig\zig.exe'
```

The build creates `dist\dxgi.dll`, a DXGI export definition generated from the local Windows library, and a fresh `dist\build.json` manifest. It does not download a compiler, install the mod or launch the game.

## Tests

From the repository directory, run the metadata and filesystem contract tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_scripts.ps1
```

To build and run the native contract fixture with Zig on `PATH`:

```powershell
New-Item -ItemType Directory -Force .\dist | Out-Null
zig cc -target x86_64-windows-gnu -O2 -Wall -Wextra -Werror .\tests\native_fps_contract_fixture.c -o .\dist\native_fps_contract_fixture.exe -lkernel32
if ($LASTEXITCODE -ne 0) { throw 'Contract fixture build failed.' }
.\dist\native_fps_contract_fixture.exe
if ($LASTEXITCODE -ne 0) { throw 'Contract fixture failed.' }
```

These tests use scratch files and synthetic inputs. They do not install the mod or exercise the guarded redirect inside Maneater. Coverage is described under Results and limits.

## Install, check and remove

Quit Maneater before installing or removing the mod. Supply either the game root or its `Maneater\Binaries\Win64` directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Mod.ps1 -Action Install -GameDirectory 'D:\SteamLibrary\steamapps\common\Maneater'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Mod.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Mod.ps1 -Action Uninstall
```

Installation places the built proxy and an unchanged copy of the verified local Windows DXGI library beside the shipping executable. No Windows DLL is included in the repository. Existing proxy files, including those belonging to another mod, are preserved rather than overwritten.

The private installation record is `.local\installation.json`. Keep it until uninstalling: removal uses that record to check ownership and hashes, and preserves files that have changed. `Status` and `Uninstall` can also take `-GameDirectory` to check the selected record.

The runtime log is `maneater_codex_fps.log` beside the installed proxy. An `INSTALLED` entry indicates that the guarded hook attached; `REDIRECTED` indicates that it handled the matching request. After a Windows DXGI update, uninstall the existing mod, rebuild and install again to recreate the verified local copy.

## How it works

The game loads an application-local `dxgi.dll`. Its exports forward graphics calls to `dxgi_codex_system.dll`, the unchanged local Windows copy. Windows documents this [export-forwarding mechanism](https://learn.microsoft.com/en-us/cpp/build/reference/exports?view=msvc-170).

The mod creates a shadow virtual-method table for the verified `t.MaxFPS` console-variable object. It changes one dispatch entry and recognizes the exact engine caller and value before substituting `120` for `60`. Executable instructions remain unchanged. Initialization runs on a worker outside the loader callback, and the hook remains resident until process exit.

## Results and limits

The original implementation passed compilation, independent source and loader review, and DXGI forwarding smoke tests. The public contract fixture covers parser boundaries, invalid pointers, unrelated-request forwarding and unknown-build rejection; it does not simulate the matching game caller. Separately, one gameplay test verified the real redirect, live 120 FPS limit and approximately 119 FPS normal cadence. The tester reported improved smoothness. Long frame-time spikes remained.

This project corrects the forced cap. It does not claim to cure crashes, shader or asset-loading hitches, or all forms of stutter. The supported build and guarded behavior are the reproducible scope of this release.

Short tests and a longer play session were reported crash-free in the same broader setup, where other crash workarounds were already present. Those observations do not isolate this mod's effect on stability or establish a universal crash fix. The installer does not apply CPU-affinity, overlay or Ansel changes.

## Independent startup-crash advice

For a game that fails to launch or shows a black screen, [Maneater's official support article](https://support.maneatergame.com/en/knowledgebase/article/cant-launch-game-black-screen) publishes this Steam Launch Options workaround:

```text
cmd /c "set OPENSSL_ia32cap=:~0x20000000 && %command%"
```

This is optional troubleshooting advice, separate from the native mod. The installer does not change launch options. Review any existing custom options before replacing them. [Intel explains the underlying OpenSSL SHA-extension issue](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/openssl-sha-crash-bug-requires-application-update.html); this workaround selects a different OpenSSL code path and does not address every cause of a gameplay crash.

## Further performance work

Future changes will require evidence from the affected runtime path and a controlled comparison with unchanged graphics. Areas to investigate include first-use resource creation and presentation pacing, followed by reversible changes only when their support and benefit are established. These are investigation goals, not implemented features.

See [CONTRIBUTING.md](CONTRIBUTING.md) for compatibility reports and contributions. This is an unofficial community project, licensed under [MIT](LICENSE). The license covers this project's original code and documentation; it does not grant rights to the game, Windows libraries or other third-party software.
