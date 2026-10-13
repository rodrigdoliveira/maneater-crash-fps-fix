# v0.9.0

**Fixes a stall introduced by the earlier area-preparation optimization.** Its memory checks could spend too long scanning a large allocation, even when reading a tiny object. The mod now reads only the data it needs.

- Preparing newly loaded areas avoids those expensive memory scans.
- Human recovery animations use the same faster reads, cutting unnecessary CPU work during combat.
- Compatibility checks, safe fallback and restore backups are retained.

The local fix was tested in gameplay on the reference Steam build and the tester confirmed: "great that works!" This release keeps that runtime implementation. The FPS, CPU, startup compatibility, loading, Ansel and overlay fixes remain included.

Run **Start.cmd** to update the launcher, then quit Maneater and click **Apply all fixes** to update the installed game fix. Your original restore history is kept. New users can extract the ready-to-run ZIP and follow the README.

The ZIP includes the compiled mod and helper, matching full source and tests. No compiler download is needed. Automated checks cover invalid memory, guarded pages, fallback, large navigation meshes, package verification and upgrade/restore. See [the validation record](gameplay-validation.md) for the tested files and scope.
