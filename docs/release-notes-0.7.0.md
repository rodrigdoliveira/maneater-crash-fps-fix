# v0.7.0

This release adds recovery, navigation and loading optimizations to the **Start.cmd → Apply all fixes → Play Maneater** workflow. The ready-to-run ZIP includes the matching compiled DLL/helper, full source and tests.

The algorithms were successfully tested in v0.7.0-preview.1 on the reference Steam build. The tester reported that they worked great; startup logs confirmed all added hooks and the FPS correction. The stable release preserves those algorithms and updates version labels, documentation and upgrade recognition.

## Compared with v0.6.0

| Area | v0.6.0 | v0.7.0 |
| --- | --- | --- |
| FPS, OpenSSL, CPU, Ansel and overlay | Guarded 60→120 request; scoped OpenSSL flag; Intel hybrid plan and Ryzen physical-core budget; recognized Ansel exclusion; Maneater-only overlay exclusion. | Retained. Ryzen support is not newly added here. |
| Get-up animation lookup | Original chest-down getter. | One guarded replacement copies `UninjuredGetupChestDown` and calls the game's original selector. Filtering, RNG and the four Blueprint getter calls' order are retained. |
| Navigation connection search | Original repeated native scans. | Temporary scoped boundary-edge index rejects only impossible searches. Included V2 groups by direction; possible matches still call the original finder. |
| Package-loading wrapper | Constructs and frees an unused `Package ` label. | Calls the same inner loader directly with the same inputs, inserted zero and return contract, avoiding the discarded string work. |
| Ready-to-run package | Prebuilt FPS proxy and launcher. | Matching combined proxy/helper, full sources and checks in one ready-to-run ZIP. |
| Upgrade/restore | Public repair ownership records. | Recognizes reviewed public/private predecessor pairs, preserves foreign files, backs up and restores the complete previous tuple and launcher-managed setup. |

The CPU instructions and settings are unchanged. The navigation V1 and V2 labels describe earlier private development stages of one filter, not two independent optimizations.

## Compatibility

The analyzed reference is the Steam executable with SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

Navigation and package loading require that full executable hash plus their exact native code and caller checks. Get-up uses strict reference PE metadata, code, function identity and reflected layout checks without hashing the whole file; a different hash retaining those checked values can still activate the getter and remains untested. **Allow an untested build** stays preselected with its apply warning and does not weaken any of these checks. The inherited FPS component retains its separate guarded opt-in checks.

The matching hidden helper runs only during attachment and then exits. It is not a profiler. Three guarded native entries are patched in process memory, while the get-up change swaps one native function pointer. The stock executable and archives are unchanged on disk.

## Evidence and remaining limits

Offline checks cover get-up copying/ownership/fallback (58,812 assertions), navigation V1/V2 decision comparisons (231,520 queries, zero tested false negatives), loading-call forwarding/unwind behavior (4,096 calls, 110,629 assertions), helper rollback and inert-process behavior. Installer tests cover previous tuples, ownership, backup/restore and interruption cases.

Gameplay feedback from the reference build was positive, with attachment confirmed in the same test logs. The offline tests provide additional contract and failure-path coverage. This is a combined-setup result on one Intel PC, without a measured FPS percentage or an isolated comparison of each optimization. See [the gameplay validation record](gameplay-validation.md). AMD gameplay and other executable builds remain outside that test scope.

The original chest-down wrapper was not fully recovered, so equivalence to the readable sibling-based replacement is an explicit inference. Navigation's temporary index relies on guarded scoped geometry and adds construction cost; some inputs can regress. Removing the unused package label changes allocator traffic and out-of-memory timing. The external attachment transaction retains a new-thread race after its final thread census. File replacements are atomic individually, not atomically across the complete tuple.

Not included: the unsuccessful recovery-event asset guard, rejected get-up list compaction, persistent navigation caches, speculative queue changes, or the reverse-punctuation prototype from the later static audit. No new graphics-quality reduction or CPU tuning is introduced.

See [README](../README.md) for running, restoration, startup status and development instructions. Keep the extracted folder and its `.local` recovery records; do not run concurrent mod installers.

Use a newly extracted folder to upgrade recognized existing public/private native files. If reusing a launcher folder with an applied journal, restore that folder's old setup before replacing its package files and applying v0.7.0.
