# 0.7.0-preview.1 — local preview

This packages the current private get-up/navigation/loading algorithms into the regular **Start.cmd → Apply all fixes → Play Maneater** workflow, with ready-built matching DLL/helper, full source and tests. It is a local preview; this work creates no GitHub release.

For an installation already running the latest private loading candidate, the algorithms are equivalent. The new work is integrated packaging, upgrade recognition and restoration, not another measured performance improvement.

## Compared with v0.6.0

| Area | v0.6.0 | Local preview |
| --- | --- | --- |
| FPS, OpenSSL, CPU, Ansel and overlay | Guarded 60→120 request; scoped OpenSSL flag; Intel hybrid plan and experimental Ryzen physical-core budget; recognized Ansel exclusion; Maneater-only overlay exclusion. | Retained. Ryzen support is not newly added here. |
| Get-up animation lookup | Original chest-down getter. | One guarded replacement copies `UninjuredGetupChestDown` and calls the game's original selector. Filtering, RNG and the four Blueprint getter calls' order are retained. |
| Navigation connection search | Original repeated native scans. | Temporary scoped boundary-edge index rejects only impossible searches. Included V2 groups by direction; possible matches still call the original finder. |
| Package-loading wrapper | Constructs and frees an unused `Package ` label. | Calls the same inner loader directly with the same inputs, inserted zero and return contract, avoiding the discarded string work. |
| Ready-to-run package | Prebuilt FPS proxy and launcher. | Matching combined proxy/helper, full sources and checks in one local ZIP. |
| Upgrade/restore | Public repair ownership records. | Recognizes reviewed public/private predecessor pairs, preserves foreign files, backs up and restores the complete previous tuple and launcher-managed setup. |

The CPU instructions and settings are unchanged. The navigation V1 and V2 labels describe earlier private development stages of one filter, not two independent optimizations.

## Compatibility

The analyzed reference is the Steam executable with SHA-256:

```text
CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0
```

Navigation and package loading require that full executable hash plus their exact native code and caller checks. Get-up uses strict reference PE metadata, code, function identity and reflected layout checks without hashing the whole file; a different hash retaining those checked values can still activate the getter and remains untested. **Allow an untested build** stays preselected with its apply warning and does not weaken any of these checks. The inherited FPS component retains its separate experimental checks.

The matching hidden helper runs only during attachment and then exits. It is not a profiler. Three guarded native entries are patched in process memory, while the get-up change swaps one native function pointer. The stock executable and archives are unchanged on disk.

## Evidence and remaining limits

Offline checks cover get-up copying/ownership/fallback (58,812 assertions), navigation V1/V2 decision comparisons (231,520 queries, zero tested false negatives), loading-call forwarding/unwind behavior (4,096 calls, 110,629 assertions), helper rollback and inert-process behavior. Installer tests cover previous tuples, ownership, backup/restore and interruption cases.

These checks do not prove fewer gameplay hitches, higher FPS or crash prevention. The reviewed combined private manifest records real-game attachment and benefit as unverified; the local packaging does not change that evidence. Earlier smooth sessions belonged to the established repair approach, and later hitches still occurred.

The original chest-down wrapper was not fully recovered, so equivalence to the readable sibling-based replacement is an explicit inference. Navigation's temporary index relies on guarded scoped geometry and adds construction cost; some inputs can regress. Removing the unused package label changes allocator traffic and out-of-memory timing. The external attachment transaction retains a new-thread race after its final thread census. File replacements are atomic individually, not atomically across the complete tuple.

Not included: the unsuccessful recovery-event asset guard, rejected get-up list compaction, persistent navigation caches, speculative queue changes, or the reverse-punctuation prototype from the later static audit. No new graphics-quality reduction or CPU tuning is introduced.

See [README](../README.md) for running, restoration, startup status and development instructions. Keep the extracted folder and its `.local` recovery records; do not run concurrent mod installers.

Use a newly extracted folder to upgrade recognized existing public/private native files. If reusing a launcher folder with an applied journal, restore that folder's old setup before replacing its package files and applying the preview.
