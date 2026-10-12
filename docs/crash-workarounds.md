# Crash-repair background and manual alternatives

The [launcher in the README](../README.md) applies these changes together: the native FPS correction, a scoped OpenSSL launch workaround, disabling the per-game Steam overlay, a reversible rename of the recognized bundled Ansel SDK, and a CPU-worker/affinity configuration when the detected hardware supports it. Run `Start.cmd`, select the game executable and choose **Apply all fixes**. Its **Restore previous setup** action uses the recorded previous files and settings. Ansel files already disabled externally are preserved.

The native DLL itself implements only the FPS correction. The advanced `Manage-Mod.ps1` installer also handles only that native mod; the GUI repair coordinates the other changes. The instructions below explain those changes and provide manual alternatives for people who do not use the GUI. They are not extra steps required after **Apply all fixes**.

Short tests and a longer play session were crash-free with the combined setup. This does not identify which change prevented a crash, establish one common cause for earlier exceptions, or prove stability on other systems. None changes graphics-quality settings, game configuration files or saved games; Ansel and overlay features have the tradeoffs described below.

The [README compatibility section](../README.md#compatibility) identifies the executable used for the investigation. Recheck compatibility after a game update. Keep a record of existing launch options and file names before trying a step; compare the same gameplay conditions and restore a change if it causes problems.

## 1. Scoped OpenSSL startup workaround

For launch failures or a black screen, [Maneater's official support article](https://support.maneatergame.com/en/knowledgebase/article/cant-launch-game-black-screen) recommends an OpenSSL capability override in Steam Launch Options. [Intel explains the older OpenSSL SHA-extension bug](https://www.intel.com/content/www/us/en/developer/articles/troubleshooting/openssl-sha-crash-bug-requires-application-update.html): this mask selects a code path that avoids the affected SHA-extension implementation. It is not a general fix for every gameplay crash.

With the game closed, open **Steam Library → Maneater → Properties → General → Launch Options**. For an otherwise empty launch-options field, use:

```text
cmd /c "set "OPENSSL_ia32cap=:~0x20000000" && %command%"
```

The quoted `set` assignment keeps separator whitespace out of the variable value. The mask matches the official workaround. The variable is scoped to this launcher and its child game process; this does not require a Windows-wide environment setting.

If you already have custom options, preserve them and review how to combine them rather than blindly replacing the field. Leave the wrapper running while the game runs. To undo the step, close the game and restore the previous launch-options value.

## 2. Disable the bundled Ansel SDK, reversibly

This workaround was tested with the investigated build; it is not an official diagnosis that Ansel caused its crashes. It disables the game's NVIDIA Ansel photo-mode integration; that capture feature becomes unavailable while the SDK is disabled. The GUI verifies the known SDK hash before using its own `.disabled-by-maneater-crash-fps-fix` filename, records the plan before renaming and rejects linked descendant folders or conflicting files. The manual alternative below uses a different filename; do not mix the two ownership schemes.

1. Quit Maneater completely. Open its installation folder through **Steam → Manage → Browse local files**.
2. Locate this path relative to the game root:

   ```text
   Engine\Plugins\Runtime\Nvidia\Ansel\Binaries\ThirdParty\AnselSDK64.dll
   ```

3. Show file-name extensions in File Explorer. In the same directory, rename `AnselSDK64.dll` to `AnselSDK64.dll.disabled`. This preserves the original file for rollback; do not delete it or substitute a downloaded DLL.
4. If that destination already exists, preserve both files and stop to identify their origin. Do not overwrite an existing backup or another mod's file. If the expected SDK is absent, skip this step.

To restore Ansel, close the game and rename the preserved file back to `AnselSDK64.dll`, only if that original-name destination is absent. If an update or Steam verification has recreated the original, do not overwrite it with an older backup. Record which file came from which game version before resolving the duplicate.

## 3. Disable the Steam overlay for Maneater

[Steam's official overlay guide](https://help.steampowered.com/en/faqs/view/3978-072C-18DF-FBF9) documents its per-game control. With the game closed, open **Steam Library → Maneater → Properties → General** and turn off **Enable the Steam Overlay while in-game**. Restart the game for the comparison.

This removes access to overlay features such as its in-game interface and screenshot tools for Maneater. It is a per-game change; leave global Steam settings alone. Restore the previous checkbox state and restart the game to undo it. Maneater's startup-support article also recommends disabling overlays, but that advice does not prove the overlay caused a particular crash.

## 4. CPU-worker budget and affinity: advanced, hardware-dependent

These two controls do different jobs. Process affinity chooses the logical processors on which game threads may run. The engine's `-corelimit=N` launch argument changes its cached core counts and derived worker budget in the verified build.

Read-only inspection during this investigation confirmed that affinity alone left the engine using its larger machine-wide worker budget. Adding a selected core limit changed the cached counts and task-graph worker groups. That verifies the budget correction, not a causal explanation for the crashes. Restricting CPU resources too far can make performance worse.

The GUI derives an applicable configuration from the detected CPU topology, rather than copying one computer's count or mask. For a manual alternative, leave these options unset unless you can determine and verify a suitable configuration:

- Derive a positive `N` from the physical cores available to the intended game workload and validate the result on that hardware. Do not use a count larger than the available resources or copy a count from another computer. Replace `N` with the chosen integer before using `-corelimit=N` in Steam Launch Options.
- If experimenting with affinity, enumerate the operating system's actual logical-processor-to-core mapping, including SMT siblings and any heterogeneous core classes. Do not assume sequential or even-numbered processor indexes correspond to a particular core type.
- A hexadecimal affinity mask sets one bit for each selected logical processor. Build it from the verified indexes, not the CPU's advertised core count. [Windows CPU-set information](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information) describes group-relative indexes, shared core indexes and efficiency classes. Processor-group systems need group-aware handling; leave affinity unset if the mapping is uncertain.
- [Windows `start /affinity`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/start) can apply a mask to a launched process. When combining it with the OpenSSL wrapper, preserve the assignment, the empty `start` window title, `/wait`, `%command%` and other existing game arguments. There is no universal mask or core-limit preset in this project.

After a complete restart, verify both the actual process affinity and the engine's cached counts/worker groups; a launch-options string alone does not establish that either took effect. Compare smoothness and long frame-time gaps in a similar scene. The appropriate settings can differ across CPUs, processor groups and game builds.

To undo the experiment, close the game and restore the prior launch options, removing only the CPU-limit argument and affinity wrapper that you added. Retain the scoped OpenSSL workaround if you still use it. These are game-process experiments, not instructions to change BIOS settings or disable system-wide CPU features.

## What remains unproven

The native DLL's verified behavior is the specific 60-to-120 FPS correction. The combined setup's crash-free sessions do not prove that the DLL, Ansel exclusion, overlay setting or CPU configuration independently fixed a crash. Long loading and gameplay hitches remained in measurements. Report real exceptions separately from normal quits, menus and Alt-Tab transitions, and share only sanitized reproduction details in public issues.
