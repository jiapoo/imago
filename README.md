# Imago

A local-first iPhone → Mac photo backup: a menu bar Mac app plus an iPhone companion app.
Photos move over your Wi-Fi with encryption and never pass through a cloud service.

## Layout

| Path | What |
|---|---|
| `Packages/ImagoKit` | Shared code: wire protocol, framing, TLS-PSK networking, pairing, library layout, hashing. Has tests. |
| `Mac/` | Mac app: Bonjour listener, `BackupStore` (verified writes, sidecars, index), status, pairing QR, library grid, menu bar. |
| `iOS/` | iPhone app: PhotoKit scan and export, upload client, QR pairing, background processing task. |
| `project.yml` | XcodeGen spec. Generates `Imago.xcodeproj` (git-ignored). |
| `docs/PROTOCOL.md` | Wire protocol and on-disk layout, enough to write a server on another platform (e.g. Windows). |

## Build

```bash
xcodegen generate && open Imago.xcodeproj
```

Set your signing team on both targets, then run `ImagoMac` and `ImagoiOS`.
The iOS Simulator has no camera, so on the Mac use **Add iPhone → Copy Link** and paste it into the app.
Debug builds also accept `-PairOnLaunch`, which opens pairing mode and prints the link to stdout.

```bash
swift test --package-path Packages/ImagoKit
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

Under each iPhone in the Mac's sidebar, **Photos** shows that phone's library laid out like the Photos
app: **Library** by Years, Months or All Photos (by day), **Favorites**, **Media Types** (Videos, Live
Photos, Portrait, Screenshots…), and **Albums**. **Free Up Space** has exact duplicates, similar shots and
bursts (found with Vision on the backed-up copies, on the Mac), large videos, and what isn't backed up yet.

Select as in Finder (click, ⌘-click, ⇧-click, ⌘A), then Favorite (or press `.`), Add to Album, Remove from
Album, or Delete (the Delete key). Space shows the backed-up copy in Quick Look. A change shows straight
away, with a clock badge until the phone has done it; doing the opposite before then takes it back
instead of sending both. Only items fully backed up on the Mac can be deleted. **Waiting for iPhone ›
To Delete** lists what's on its way out, with **Keep on iPhone** to change your mind.

How changes reach the phone:

- **Imago open on the iPhone:** the phone keeps a live connection to the Mac, and the toolbar says
  **Connected**. Changes arrive within a second. With **Apply changes from your Mac** on (the default),
  favorites and albums are made right away; deletions show iOS's own confirmation, once for a batch, and go
  to Recently Deleted. Turn it off to review every change in the app first. While connected, photos the Mac
  hasn't backed up yet show previews the phone sends.
- **Imago not open:** changes wait, and go to the phone when you next open Imago or at its next backup.

The Mac's view is the library as of the phone's last backup, plus what's been done since. Changes made on
the phone itself show up after its next backup. See `docs/PROTOCOL.md` §6.1–6.2.

## Browsing and organizing on the Mac

**Library** shows every photo and video from every iPhone by day, wherever it is in the backup folder.
**Folders** in the sidebar are real folders on the backup drive (`Folders/<name>`), so they stay usable
without the app. Select items (click, ⌘-click, ⇧-click, ⌘A), then from the bar at the bottom:

- **Move To** a Folder, or drag items onto one in the sidebar. Their sidecars go with them, and the
  phone isn't asked for them again. **Back to iPhone's Folder** moves them back into the dated layout.
- **Remove from iPhone** queues a deletion for the phone (only for items fully backed up). It happens
  once you confirm it on the iPhone.
  A Folder with items still on an iPhone says so at the top, with a button to remove them all there:
  move today's tennis videos into Folders/Tennis, then remove them from the iPhone in one step.
- **Trash** moves them to the Trash and stops backing them up from the phone.

Space opens Quick Look, ⌘O or a double-click opens the file in its default app (Preview, QuickTime…),
and Delete moves it to the Trash. Files put into a Folder in Finder or by
AirDrop show up too. A phone's file moved there in Finder is recognized by name, size and checksum.

## Not built yet

- A second destination (external drive or NAS) and a "copies" count
- Scheduled checksum scrubs and restore drills
- Requiring two verified copies before the Mac offers to delete from the iPhone
- Moving existing backups when the location changes (today they stay where they were)
- Keeping pairings when the library moves to another Mac: `library.json` keeps each phone's folder, but each phone scans the new Mac's QR code once
- Deduplicating photos that two phones share through iCloud Photos (each phone keeps its own copy)
- Incremental scans using `PHPhotoLibrary` change tokens (today every backup reads the whole library's metadata)
- Sending changes made in Photos on the iPhone to the Mac during a live session (today they show after the next backup)
