# Contributing to Maneater Crash & FPS Fix

Contributions should make the complete repair launcher and FPS correction easier to verify, use and maintain. Additional game builds and performance changes need evidence; keep current graphics and gameplay behavior intact.

Use [GitHub issues](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/issues) for reports and proposed changes.

## Report a problem

Include the following in an issue:

- Game storefront, build number and executable SHA-256.
- Windows version and the mod revision or source commit used.
- Launcher action and error, or development command, with personal paths removed.
- Steps to reproduce, expected behavior and actual behavior.
- Whether the guarded hook attached and redirected the request. A short, sanitized log excerpt is enough.
- Whether experimental untested-build mode was selected, and whether the warning was accepted for that apply.

For an untested build, report installation and runtime outcomes separately. Installed files are not proof of a working FPS correction. A native `INSTALLED` marker means attachment; `REDIRECTED` verifies a matching request, while `PASS-THROUGH` means the runtime guard declined. Use entries from the launch being reported, since the log can contain older sessions. Include the actual executable hash and the remaining symptoms. Do not describe an opt-in or one successful launch as validation of that game version.

For performance reports, separate steady gameplay from loading, menus, Alt-Tab and normal quitting. If available, include a compact frame-time summary and the scene tested. CPU and GPU models are optional context, not prerequisites for reporting.

For crash reports, distinguish an exception or crash report from a normal quit. Identify other workarounds already in use and avoid attributing a crash-free session to one change unless a controlled comparison supports it. The current native implementation corrects the FPS cap; it does not implement a verified crash-prevention change.

Do not post game or Windows binaries, saves, installation records, crash dumps or raw traces in public issues. These can contain personal paths or process data. Remove usernames, absolute paths and unrelated identifiers from excerpts.

## Change the code

- Explain the concrete problem and resulting behavior.
- Preserve the original setter's ABI, flags, callbacks and unrelated requests.
- Keep exact compatibility guards and safe forwarding for unrecognized runtime states.
- Keep tested-build checks as the default. Experimental use must be explicit, accepted for each apply, restricted to a verified Steam installation, and recorded with the actual game hash. It must preserve runtime layout/caller and file-ownership safeguards.
- Preserve existing files during installation and remove only verified, owned files during uninstall.
- Keep generated binaries, local Windows copies and private test artifacts out of commits.

Build with warnings treated as errors. Test the contracts affected by the change, including rejection paths; report exactly what ran. Cover untested-build acceptance and refusal, journal identity, restore, and installed-versus-runtime reporting when changing those paths. An opt-in is an experiment, not a supported-build entry. New verified executable support needs independent validation of the object, method and caller before adding a build. Document any untested Windows or hardware assumptions.

Performance claims need comparable scenes, loading/cache conditions and measurement windows. Report remaining long gaps, missing capture tails and normal quits rather than counting absent data as smooth gameplay. Changes that preserve the image should still be checked for unintended rendering differences.

Keep the current evidence scopes separate: gameplay verification used the earlier tested-build FPS v0.1 core. Native v0.2's added experimental-build and mapped-image guards were checked by contract fixtures and source review, without a new gameplay test of the updated DLL.

## License and scope

Submit original material or identify its source and compatible license. Contributions to this project's original code and documentation are distributed under its [MIT license](LICENSE). Keep any required third-party notices when introducing a dependency.

The repository is source-only; the launcher builds automatically. Changes beyond the retained repair bundle require support, reversibility and evidence of benefit.
