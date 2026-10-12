# v0.7.0 gameplay validation

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
