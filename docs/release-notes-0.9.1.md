# v0.9.1

**Fixes installation errors caused by differences between Windows versions.** A complete package could previously show a misleading "ready-to-run mod bundle is missing" error when its graphics functions differed from those on the PC used to build it.

- The launcher now prepares the graphics wrapper for your own Windows installation. No compiler or extra download is needed.
- Errors identify missing files, changed files, invalid packages or Windows graphics problems separately, with a diagnostic code and report to share.
- All existing gameplay, FPS, CPU and stability fixes are included. Upgrade and restore backups are retained.

The local package was tested on the reference PC and reported to work great. Automated tests also cover different graphics-function layouts, forwarding by name and number, package verification, repeated installation, upgrade and restore. See [the validation record](gameplay-validation.md).

Run **Start.cmd** to update, then quit Maneater and click **Apply all fixes**. New users can download and extract **Maneater-Crash-FPS-Fix.zip**, then run **Start.cmd**.
