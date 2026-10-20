# Photo Backup

A local-first iPhone → Mac photo backup: a menu bar Mac app plus an iPhone companion app.
Photos move over your Wi-Fi with encryption and never pass through a cloud service.

## Layout

| Path | What |
|---|---|
| `Packages/PhotoBackupKit` | Shared code: wire protocol, framing, TLS-PSK networking, pairing, library layout, hashing. Has tests. |
| `Mac/` | Mac app: Bonjour listener, `BackupStore` (verified writes, sidecars, index), status, pairing QR, library grid, menu bar. |
| `iOS/` | iPhone app: PhotoKit scan and export, upload client, QR pairing, background processing task. |
| `project.yml` | XcodeGen spec. Generates `PhotoBackup.xcodeproj` (git-ignored). |
| `docs/PROTOCOL.md` | Wire protocol and on-disk layout, enough to write a server on another platform (e.g. Windows). |

## Build

```bash
xcodegen generate && open PhotoBackup.xcodeproj
```

Set your signing team on both targets, then run `PhotoBackupMac` and `PhotoBackupiOS`.
The iOS Simulator has no camera, so on the Mac use **Add iPhone → Copy Link** and paste it into the app.
Debug builds also accept `-PairOnLaunch`, which opens pairing mode and prints the link to stdout.

```bash
swift test --package-path Packages/PhotoBackupKit
```

## Pairing

1. **Add iPhone** on the Mac advertises a second `_photobackup._tcp` service (TXT `mode=pair`) with a fresh one-time key, shown as a QR code.
2. The phone connects with that key and sends `pairRequest`; the Mac replies with a key made for that phone alone.
3. Afterwards the phone connects to the backup service (TXT `mode=backup`) with its own key. **Remove iPhone** deletes the key, so that phone is refused.

A pairing lasts until it's removed on the Mac or unpaired on the phone. It works whenever both devices are on the same network.

## How a backup works

1. The phone browses Bonjour (`_photobackup._tcp`) for the Mac whose TXT `id` matches its pairing.
2. TLS opens with the phone's own pre-shared key. If the backup drive is unplugged, the Mac answers `unavailable`.
3. The phone sends its manifest in batches of 500 assets. The Mac replies with the files it lacks
   and how many bytes of each it already holds, so interrupted files resume.
4. Each file is exported from PhotoKit (downloading iCloud originals if needed), streamed in 512 KB chunks,
   and checked against a SHA-256 before the Mac moves it into place.

On disk (default `~/Pictures/Photo Backup`; any folder, external drive or network drive can be chosen):

```
Jia's iPhone/2026/10/2026-10-20_143012_IMG_4821.HEIC         original
Jia's iPhone/2026/10/2026-10-20_143012_IMG_4821.MOV          Live Photo motion
Jia's iPhone/2026/10/2026-10-20_143012_IMG_4821_edited.JPG   rendered edit
Jia's iPhone/2026/10/2026-10-20_143012_IMG_4821.json         metadata, albums, checksums
Jia's iPhone/.photobackup/index.json                         cache; rebuildable from the sidecars
```

Deletions on the phone never delete anything on the Mac. Interrupted files resume from the last byte received.

## Overnight backups

The phone schedules a `BGProcessingTask` that requires power and network. iOS picks the time, usually overnight; it's likely most nights but never guaranteed, and it doesn't run if the app was swiped away. During a session the Mac holds a power assertion so it doesn't idle-sleep. To accept backups while asleep, turn on **Wake for network access**.

## Managing the iPhone's library from the Mac

Each iPhone in the Mac's sidebar has **Manage Library**: the phone's library as of its last backup, with
suggestions for freeing space (exact duplicates, similar shots and bursts, large videos, screenshots, by year)
and album and favorite tools. Similar shots are found with Vision on the backed-up copies, on the Mac.

Changes don't happen right away. The Mac queues them, and hands them to the phone at its next backup. The
iPhone app shows **"Your Mac suggests N changes"**, and the user approves or declines each one. Deletions
also go through iOS's own confirmation and land in Recently Deleted. Only items fully backed up on the Mac
can be deleted. See `docs/PROTOCOL.md` §6.1.

## Not built yet

- A second destination (external drive or NAS) and a "copies" count
- Scheduled checksum scrubs and restore drills
- Requiring two verified copies before the Mac offers to delete from the iPhone
- Moving existing backups when the location changes (today they stay where they were)
- Deduplicating photos that two phones share through iCloud Photos (each phone keeps its own copy)
- Incremental scans using `PHPhotoLibrary` change tokens (today every backup reads the whole library's metadata)
