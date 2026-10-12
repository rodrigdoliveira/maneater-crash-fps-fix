# Contributing to Maneater Crash & FPS Fix

Contributions should make the FPS correction easier to verify, build and maintain. Additional game builds and performance changes need evidence; keep current graphics and gameplay behavior intact.

Use [GitHub issues](https://github.com/rodrigdoliveira/maneater-crash-fps-fix/issues) for reports and proposed changes.

## Report a problem

Include the following in an issue:

- Game storefront, build number and executable SHA-256.
- Windows version and the mod revision or source commit used.
- Build or installation command, with personal paths removed.
- Steps to reproduce, expected behavior and actual behavior.
- Whether the guarded hook attached and redirected the request. A short, sanitized log excerpt is enough.

For performance reports, separate steady gameplay from loading, menus, Alt-Tab and normal quitting. If available, include a compact frame-time summary and the scene tested. CPU and GPU models are optional context, not prerequisites for reporting.

For crash reports, distinguish an exception or crash report from a normal quit. Identify other workarounds already in use and avoid attributing a crash-free session to one change unless a controlled comparison supports it. The current native implementation corrects the FPS cap; it does not implement a verified crash-prevention change.

Do not post game or Windows binaries, saves, installation records, crash dumps or raw traces in public issues. These can contain personal paths or process data. Remove usernames, absolute paths and unrelated identifiers from excerpts.

## Change the code

- Explain the concrete problem and resulting behavior.
- Preserve the original setter's ABI, flags, callbacks and unrelated requests.
- Keep exact compatibility guards and safe forwarding for unrecognized runtime states.
- Preserve existing files during installation and remove only verified, owned files during uninstall.
- Keep generated binaries, local Windows copies and private test artifacts out of commits.

Build with warnings treated as errors. Test the contracts affected by the change, including rejection paths; report exactly what ran. New executable support needs independent validation of the object, method and caller before adding a build. Document any untested Windows or hardware assumptions.

Performance claims need comparable scenes, loading/cache conditions and measurement windows. Report remaining long gaps, missing capture tails and normal quits rather than counting absent data as smooth gameplay. Changes that preserve the image should still be checked for unintended rendering differences.

## License and scope

Submit original material or identify its source and compatible license. Contributions to this project's original code and documentation are distributed under its [MIT license](LICENSE). Keep any required third-party notices when introducing a dependency.

The repository is source-only. Optimizations beyond the verified cap correction remain proposals until their support, reversibility and measured benefit are established.
