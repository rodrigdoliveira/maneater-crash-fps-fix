# Contributing to Maneater Crash & FPS Fix

Contributions should make the complete repair launcher and native optimizations easier to verify, use and maintain. Additional game builds and performance changes need evidence; keep current graphics and gameplay behavior intact.

Use [GitHub issues](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/issues) for reports and proposed changes.

## Report a problem

Include the following in an issue:

- Game storefront, build number and executable SHA-256.
- Windows version and the mod revision or source commit used.
- Launcher action and error, or development command, with personal paths removed.
- Steps to reproduce, expected behavior and actual behavior.
- Whether the guarded hook attached and redirected the request. A short, sanitized log excerpt is enough.
- Whether untested-build mode was selected, and whether the warning was accepted for that apply.

For an untested build, report installation and runtime outcomes separately. Installed files are not proof of a working FPS correction. A native `INSTALLED` marker means attachment; `REDIRECTED` verifies a matching request, while `PASS-THROUGH` means the runtime guard declined. Use entries from the launch being reported, since the log can contain older sessions. Include the actual executable hash and the remaining symptoms. Do not describe an opt-in or one successful launch as validation of that game version.

For performance reports, separate steady gameplay from loading, menus, Alt-Tab and normal quitting. If available, include a compact frame-time summary and the scene tested. CPU and GPU models are optional context, not prerequisites for reporting.

AMD Ryzen worker-budget support has not been tested during AMD gameplay. Reports should include physical/logical core counts, the applied core limit and whether a comparison without the CPU limit was better or worse. Keep Windows/AMD scheduling intact; do not infer an X3D cache CCD from processor numbering or add a fixed affinity preset. Fixture coverage proves planning and restoration, not a performance gain.

For crash reports, distinguish an exception or crash report from a normal quit. Identify other workarounds already in use and avoid attributing a crash-free session to one change unless a controlled comparison supports it. The native implementation corrects the FPS request and reduces work in guarded recovery, navigation and loading paths. A combined-setup result does not prove which change prevented an individual crash.

Do not post game or Windows binaries, saves, installation records, crash dumps or raw traces in public issues. These can contain personal paths or process data. Remove usernames, absolute paths and unrelated identifiers from excerpts.

## Change the code

- Explain the concrete problem and resulting behavior.
- Preserve the original setter's ABI, flags, callbacks and unrelated requests.
- Keep exact compatibility guards and safe forwarding for unrecognized runtime states.
- Check the build identity every time. The GUI preselects the untested-build option, but an untested apply still requires acceptance of its warning; command-line installation requires an explicit flag. Keep the verified Steam installation, recorded game hash, runtime layout/caller and file-ownership safeguards.
- Preserve existing files during installation and remove only verified, owned files during uninstall.
- Keep generated binaries, local Windows copies and private test artifacts out of commits.

Build with warnings treated as errors. Test the contracts affected by the change, including rejection paths; report exactly what ran. Cover untested-build acceptance and refusal, journal identity, restore, and installed-versus-runtime reporting when changing those paths. An opt-in is an experiment, not a supported-build entry. New verified executable support needs independent validation of the object, method and caller before adding a build. Document any untested Windows or hardware assumptions.

Performance claims need comparable scenes, loading/cache conditions and measurement windows. Report remaining long gaps, missing capture tails and normal quits rather than counting absent data as smooth gameplay. Changes that preserve the image should still be checked for unintended rendering differences.

The v0.7.0 combined algorithms passed a gameplay test on the reference build and one Intel PC, with native attachment confirmed in the logs. Keep that result separate from offline fixture coverage, AMD support and untested executable versions. See [the validation record](docs/gameplay-validation.md).

## License and scope

Submit original material or identify its source and compatible license. Contributions to this project's original code and documentation are distributed under its [MIT license](LICENSE). Keep any required third-party notices when introducing a dependency.

The Git repository and GitHub's automatic source archives contain developer sources. The custom ready-to-run release ZIP additionally includes the compiled project mod, its matching build manifest and export definition, and full sources. Normal Apply validates that package without compiling or downloading a compiler. Developers build manually with `build.ps1`; installation copies the verified Windows DXGI DLL from the user's own PC, never from a release asset.

Package releases from an explicit file list. Match the compiled DLL, manifest, export definition and source hashes to the release source revision. Exclude Windows/game DLLs, compilers, PDBs, test executables, caches, logs and `.local` records or backups. Validate the extracted ZIP, its DLL hash, exports and dependencies, and publish the ZIP checksum. Portable graphics installation personalizes only the reserved read-only `.dxgifwd` section, export-directory fields and checksum. Preserve exact local names/ordinals, aliases and ordinal-only exports; verify the staged image and record its personalized hash for upgrade/restore. Never relax the native executable or object-layout guards. Cover distinct package failures, Windows-table variations and compiler/download absence before repair changes. The loader fixtures execute only authored inert DLLs, never the production mod or Maneater.

Changes beyond the retained repair bundle require support, reversibility and evidence of benefit.
