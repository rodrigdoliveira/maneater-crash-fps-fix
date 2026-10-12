# v0.8.0

**Start.cmd now opens a separate updater before the launcher.** It checks the latest regular GitHub release, downloads the ready-to-run ZIP and checksum, verifies the package, replaces the launcher files in place and opens the updated launcher. After the initial installation, ordinary launcher updates no longer require manual extraction.

The bootstrap has no launcher-version dependency and remains separate from normal launcher updates. It uses a fixed package protocol and keeps `Start.cmd`, `Updater.ps1` and `scripts/Update.psm1` stable. A future incompatible bootstrap format will ask for a full-package installation instead of applying an unsupported update.

The updater preserves `.local`, restore records, original backups and extra user files. Package files modified after installation cause a refusal rather than an overwrite. A saved transaction and verified rollback copies support recovery after interruption. An open launcher or repair operation blocks file replacement. Update failures can fall back to the complete installed package.

When the bundled game fix changes, **Apply all fixes** upgrades a valid applied setup while retaining its original restore history. Failure restores the previous working native files and ownership. Updating the launcher does not launch Maneater or change its files by itself.

This release retains the gameplay-tested FPS, recovery, navigation and loading algorithms and the existing CPU/OpenSSL/Ansel/overlay setup. It introduces launcher updating and upgrade handling, without a new gameplay-performance claim.

See [README](../README.md) for installation and restoration. The ready-to-run ZIP includes compiled binaries, matching full source, the updater package inventory and isolated tests.
