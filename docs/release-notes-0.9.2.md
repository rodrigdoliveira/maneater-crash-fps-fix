# v0.9.2

**Fixes manual selection of a valid Steam installation.** Choosing the correct executable could still report that Maneater was missing or ambiguous when another Steam library contained a second copy or stale installation record.

- Automatic detection still runs first. If it finds no game or multiple copies, use **Choose game...** to select **Maneater.exe** or **Maneater-Win64-Shipping.exe**.
- The selected copy is checked against its own registered Steam library and Maneater installation manifest. Other copies, duplicate references to the same library and an outdated library app summary no longer block a valid selection.
- Errors explain missing or unreadable Steam records, unregistered libraries and folder mismatches, with steps to find the game in Steam.
- Existing FPS, gameplay, Windows graphics compatibility, CPU and stability fixes remain included. Upgrade and restore retain the original backups.

Automated tests cover automatic discovery, manual selection of either installed copy, both executable names, custom game folders and invalid or missing Steam records. Gameplay implementation is retained apart from version labels; this release adds no new gameplay validation. See [the existing validation record](gameplay-validation.md).

Run **Start.cmd** to receive the update. Keep the launcher folder and its `.local` backups. If the launcher requests a game-fix update, quit Maneater and use **Apply all fixes**.

New users can download and extract **Maneater-Crash-FPS-Fix.zip**, then run **Start.cmd**. To locate the correct executable, use **Steam → Maneater → Manage → Browse local files**.
