# Gameplay validation

## v0.9.0 memory-check fix

The tester played with the installed local memory-check fix and reported: "great that works!" The v0.9.0 release retains that runtime implementation, with release version labels and matching build metadata refreshed.

The fix removes expensive memory-region scans from navigation snapshot reads and human recovery-animation input reads. Navigation uses bounded reads of the required data, with original layout/identity checks and fallback. Recovery keeps the original animation selector and write checks.

The gameplay-tested local DLL SHA-256 was `06CF53D9174E600D9745C16EB4F51B50C5568B41D831A6A5E534BFC000BEB3CC`; its helper SHA-256 was `898C59D575AFF5DD9F6CDB0F46A2DEB5F1700DF80A5DDFE2A86AE1C71B1DCB7A`. The test used the reference Steam build 7837297 on an Intel Core i9-13900K with NVIDIA GeForce RTX 4070.

This is positive feedback for the combined setup, rather than a timed FPS comparison. The rebuilt release DLL has a different hash; the packaged manifest records both the release hash and the tested local hash. It does not establish results on AMD hardware or other game builds.

Automated tests cover inaccessible and guarded memory, partial reads and cleanup, original fallback, large navigation meshes, write checks, package verification and upgrade/restore. Raw recordings, private paths and game files are excluded from publication.

## Earlier v0.7.0 validation

The tester ran the v0.7.0-preview.1 package and reported: "they work great! i just tested it." The v0.7.0 release preserves those algorithms; version labels, log text, documentation and predecessor recognition were updated for publication.

The test used the reference Steam build 7837297 on the Intel test PC. The test report is positive gameplay feedback for the combined setup. It is not a timed benchmark or an isolated comparison of individual optimizations, and it does not validate AMD hardware or another game build.

Tested files:

| File | SHA-256 |
| --- | --- |
| Maneater-Win64-Shipping.exe | `CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0` |
| dxgi.dll | `85B190F0AD305F9FD0D9C9A676D61B4179FB736F32D6ED3C4BC9E468F80208BF` |
| ManeaterAreaHelper.exe | `898C59D575AFF5DD9F6CDB0F46A2DEB5F1700DF80A5DDFE2A86AE1C71B1DCB7A` |

Read-only inspection of the test's startup output confirmed:

- The recovery getter pointer was installed with the original selector/RNG retained.
- The navigation and package-loading hooks were installed. The attachment report recorded three successful patch attempts, with zero rollback or resume errors.
- The FPS log recorded a matching native 60 FPS request redirected to 120 through the original setter.

Offline validation also covers the installer/restore workflow, native forwarding and ownership, navigation rejection decisions, x64 unwind behavior and attachment rollback. Raw logs, process identifiers, personal paths, game files and captures are excluded from the repository and release.

Known technical limits are documented in the [release notes](release-notes-0.7.0.md#evidence-and-remaining-limits). The positive gameplay result supports publishing v0.7.0 as a regular release; it does not establish identical results on every PC.
