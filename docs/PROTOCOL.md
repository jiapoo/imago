# Imago protocol, version 6

This is everything a server needs to accept backups from the Imago iPhone app:
discovery, encryption, pairing, the messages, and how files are laid out on disk.
The Mac app is one implementation. A Windows or Linux server that follows this document
works with the same iPhone app, unchanged.

The source of truth is `Packages/ImagoKit`. If this document and the code disagree,
the code wins and this document has a bug. The examples below are real output from that code.

Terms: the **phone** is the client and the **server** is the Mac (or any other implementation).
"MUST" marks what the phone relies on. Everything else describes what the Mac does today.

---

## 1. Discovery (Bonjour / mDNS)

The server advertises DNS-SD services of type **`_photobackup._tcp`** in the local domain.

| TXT key | Value |
|---|---|
| `id` | The server's ID, a UUID string made once and kept forever. The phone finds its server by this, not by name. |
| `mode` | `backup` or `pair`. A missing `mode` is treated as `backup`. |

There are two services:

- **Backup service** (`mode=backup`): always advertised. Instance name: the computer's name, e.g. `Studio Mac`.
- **Pairing service** (`mode=pair`): advertised only while the user has "Add iPhone" open.
  Instance name: `<computer name> (Pairing)`. It runs on its own port with its own key (see §3).

The phone browses for `_photobackup._tcp` and picks the first result whose `id` and `mode` both match.
It gives up after 10 seconds. The Mac also allows peer-to-peer Wi-Fi (AWDL); other platforms don't
need to. The port is whatever the OS assigns. The phone reads it from the service record.

On Windows, mDNS/DNS-SD is available through `DnsServiceRegister` (Windows 10 and later) or Bonjour for Windows.

## 2. Transport: TCP + TLS with a pre-shared key

Every connection is TCP wrapped in **TLS with a pre-shared key (PSK)**. There are no certificates.

| | |
|---|---|
| Cipher suite | `TLS_PSK_WITH_AES_128_GCM_SHA256` (IANA `0x00A8`), the only one offered |
| PSK identity | UTF-8 bytes of a string: `pair` for pairing, the phone's device ID for backups |
| PSK | 32 random bytes |
| Keepalive | TCP keepalive on: first probe after 10 s idle, then every 5 s, give up after 4 (≈30 s). Recommended, not required |

The negotiated version is TLS 1.2 (`0x0303`, checked on a loopback connection). Windows' built-in TLS
(SChannel) has poor PSK support, so a Windows server should use OpenSSL (`SSL_CTX_set_psk_server_callback`)
or rustls. The server must also be able to export keying material (RFC 5705) for the hello proof (§6),
which OpenSSL does with `SSL_export_keying_material`.

A wrong key fails the TLS handshake. The phone reports that as "Your Mac didn't accept this iPhone".

**Server-side key lookup:** the backup service holds one PSK per paired phone, keyed by
identity = device ID. A server with no paired phones must still start TLS, so the Mac
installs one random key under the identity `none`, which admits nobody.

TLS only proves the phone holds *one* of the server's keys. Apple's API can't tell the Mac which one,
so the phone also proves its identity inside the session with the `hello` proof (§6).

## 3. Pairing

Pairing gives a phone its own long-term key. It runs only while "Add iPhone" is open.

### 3.1 The QR code

The server makes a fresh **pairing code** and shows it as a QR code (or a copyable link):

```
photobackup://pair?d=<base64url(JSON), no padding>
```

The JSON is:

```json
{"serverID":"<server id>","serverName":"Studio Mac","secret":"<standard base64 of 32 bytes>"}
```

The phone rejects a code whose `secret` isn't exactly 32 bytes. Note the two encodings: the whole
JSON is base64**url**-encoded without padding, but `secret` inside it is ordinary base64 with padding.

### 3.2 The exchange

The phone connects to the **pairing service** with PSK identity `pair` and PSK = `secret`.

```
phone → server   pairRequest { deviceID, deviceName, protocolVersion: 5 }
server → phone   paired      { deviceKey: <32 random bytes>, serverName }
```

Then both sides close. The server MUST:

1. Reject a `protocolVersion` other than 4 or 5 by closing the connection without replying.
2. Store `deviceKey` under identity `deviceID` and add it to the backup service's keys, restarting
   that listener if needed.
3. If `deviceID` is already paired, replace its key and keep its existing folder (this is how a
   reinstalled app reconnects to its old backups; the phone keeps its device ID in the Keychain).
   If it isn't paired but the backup location's `library.json` lists it (§7.6), use the folder listed
   there: the phone backed up into this library from another Mac, or before it was removed.
4. Make a new pairing code right after a successful pairing, so one code pairs one phone.

**Removing** a phone deletes its key. Its photos stay on disk.

## 4. Framing

Every message in both directions is one frame. All integers are **big-endian**.

```
[u32 length][body]               length = number of bytes in body, at most 16 MiB (16 777 216)
body = [u8 kind][payload]
  kind 0  control:  payload = UTF-8 JSON of one control message (§5)
  kind 1  chunk:    payload = [u16 keyLength][key JSON][u64 offset][raw file bytes]
```

A receiver MUST drop the connection on a length over 16 MiB, an unknown kind, or a malformed body.
A control message whose name it doesn't know (one key, not listed in §5.2) comes from a newer version:
it SHOULD skip it and carry on.

Chunks carry raw bytes so photos aren't inflated by base64. The phone sends file data in pieces of
**512 KiB** (the last piece may be shorter). `key JSON` is a `ResourceKey` (§5.1), and `offset` is
where in the file this piece starts.

Real chunk frame for key `ABC/L0/001#photo@original`, offset 7, data `AA BB`:

```
00 00 00 4c                      length 76
01                               kind 1 (chunk)
00 3f                            key JSON is 63 bytes
7b 22 61 73 … 22 7d              {"assetID":"ABC\/L0\/001","revision":"original","kind":"photo"}
00 00 00 00 00 00 00 07          offset 7
aa bb                            file bytes
```

## 5. Control messages

JSON conventions (Swift `Codable` output, which a parser on any platform reads fine):

- Each message is an object with **one key**, the message name, whose value holds the fields.
  Fields with no name in Swift appear as `"_0"`. A message with no fields is `{"goodbye":{}}`.
- Key order is not fixed, and `/` may be escaped as `\/`.
- Binary data (`deviceKey`, `proof`) is standard base64 with padding.
- Dates are ISO 8601 in UTC, written without fractional seconds: `"2026-10-20T14:30:12Z"`.
  Fractional seconds are dropped. A reader should accept time zone offsets.
- An optional field that is empty is **left out**, not sent as `null`.

### 5.1 Shared types

**ResourceKey**: the identity of one file.

```json
{"assetID":"ABC/L0/001","kind":"photo","revision":"original"}
```

- `assetID`: the iPhone's `PHAsset.localIdentifier`. Treat it as opaque. It contains `/`.
- `kind`: one of the values below.
- `revision`: `"original"` for originals. For edits it is the asset's modification time in whole
  Unix seconds, e.g. `"1792506612"`, so editing a photo again produces a new key.
- Its text form, used as an index key, is `assetID#kind@revision`.

| `kind` | What it is | Edit? |
|---|---|---|
| `photo` | Original still (HEIC, JPEG, DNG…) | no |
| `video` | Original video | no |
| `alternatePhoto` | Second original, e.g. the JPEG of a RAW+JPEG pair | no |
| `pairedVideo` | Live Photo motion | no |
| `fullSizePhoto` | Rendered edit of a photo | yes |
| `fullSizeVideo` | Rendered edit of a video | yes |
| `fullSizePairedVideo` | Rendered edit of Live Photo motion | yes |
| `adjustmentData` | The edit recipe (a plist) | yes |

**AssetMetadata**: one photo or video.

```json
{
  "assetID": "ABC/L0/001",
  "originalFilename": "IMG_4821.HEIC",
  "creationDate": "2026-10-20T14:30:12Z",
  "modificationDate": "2026-10-20T14:30:12Z",
  "mediaType": "photo",
  "pixelWidth": 4032, "pixelHeight": 3024,
  "duration": 0,
  "isFavorite": false,
  "location": {"latitude": 37.33, "longitude": -122.0, "altitude": 10},
  "albums": ["Trips"],
  "subtypes": ["livePhoto", "hdr"],
  "burstID": "8E1A…"
}
```

`originalFilename` is the primary file's name, and the asset's files are named after it.
`mediaType` is `"photo"` or `"video"`. `duration` is in seconds (0 for photos).
`subtypes` lists PhotoKit subtypes: `screenshot`, `screenRecording`, `livePhoto`, `panorama`, `hdr`,
`depthEffect`, `highFrameRate`, `timelapse`, `cinematic`, `spatial`. `burstID` is shared by photos of one burst.
`creationDate`, `modificationDate`, `location`, `subtypes` and `burstID` can be absent.

**ResourceDescriptor**: one file of an asset.

```json
{"key": <ResourceKey>, "originalFilename": "IMG_4821.HEIC", "uti": "public.heic"}
```

`uti` is an Apple Uniform Type Identifier (`public.heic`, `public.jpeg`, `com.apple.quicktime-movie`…).

**ManifestEntry**: `{"metadata": <AssetMetadata>, "resources": [<ResourceDescriptor>, …]}`

**LibraryChange**: a change the server asks the phone to make (§6.1).

```json
{"id":"<UUID>","action":{"addToAlbum":{"_0":"Trip"}},"assetIDs":["ABC/L0/001"],"createdAt":"…","bytes":123}
```

`action` is one of `{"delete":{}}`, `{"addToAlbum":{"_0":"<title>"}}`, `{"removeFromAlbum":{"_0":"<title>"}}`,
`{"setFavorite":{"_0":true}}`, and from version 6 `{"deleteAlbum":{"_0":"<title>"}}` (its `assetIDs` is
empty). `bytes` (deletions) is about how much space it frees. The server never sends a phone a change
newer than the version it said hello with.

**ChangeReport**: `{"changeID":"<UUID>","outcome":"applied","assetCount":12,"date":"…","detail":"…"}`.
`outcome` is `applied`, `declined` (by the user) or `failed` (with `detail`).

**ResumePoint**: `{"key": <ResourceKey>, "offset": 1024}`, a file the server still needs and how
many bytes of it the server already has.

### 5.2 Messages

| Message | Direction | JSON |
|---|---|---|
| `pairRequest` | phone → server | `{"pairRequest":{"deviceID":"…","deviceName":"Jia's iPhone","protocolVersion":5}}` |
| `paired` | server → phone | `{"paired":{"deviceKey":"<base64>","serverName":"Studio Mac"}}` |
| `hello` | phone → server | `{"hello":{"deviceID":"…","deviceName":"…","protocolVersion":5,"proof":"<base64 of 32 bytes>"}}` |
| `welcome` | server → phone | `{"welcome":{"serverName":"Studio Mac"}}` |
| `unavailable` | server → phone | `{"unavailable":{"reason":"<shown to the user>"}}` |
| `manifest` | phone → server | `{"manifest":{"_0":[<ManifestEntry>, …]}}` |
| `need` | server → phone | `{"need":{"_0":[<ResumePoint>, …]}}` |
| `beginResource` | phone → server | `{"beginResource":{"_0":<ResourceDescriptor>,"metadata":<AssetMetadata>,"size":12345}}` |
| `endResource` | phone → server | `{"endResource":{"_0":<ResourceKey>,"sha256":"<64 lowercase hex>"}}` |
| `stored` | server → phone | `{"stored":{"_0":<ResourceKey>}}` |
| `failed` | server → phone | `{"failed":{"_0":<ResourceKey>,"reason":"…"}}` |
| `goodbye` | phone → server | `{"goodbye":{}}` |
| `manifestEnd` | phone → server | `{"manifestEnd":{"albums":["Trip","Family"]}}`, every album title, empty ones too |
| `changes` | server → phone | `{"changes":{"_0":[<LibraryChange>, …]}}`, maybe empty |
| `changeReport` | phone → server | `{"changeReport":{"_0":[<ChangeReport>, …]}}` |
| `live` | phone → server | `{"live":{}}`, version 5: start a live session (§6.2) |
| `thumbnailRequest` | server → phone | `{"thumbnailRequest":{"_0":["<assetID>", …]}}`, version 5 |
| `thumbnails` | phone → server | `{"thumbnails":{"_0":[{"assetID":"…","jpeg":"<base64>"}, …]}}`, version 5; at most 360 px on the long side |

## 6. A backup session

The phone connects to the **backup service** with PSK identity = its device ID and PSK = its device key.

```
phone                                         server
  hello ─────────────────────────────────────▶
       ◀──────────────────────────── welcome  (or unavailable, then close)
  changeReport ──────────────────────────────▶   only if it has any; no reply
  manifest (≤ 500 entries) ──────────────────▶
       ◀─────────────────────────────── need
  … repeated until the whole library is sent …
  manifestEnd ───────────────────────────────▶
       ◀──────────────────────────── changes
  for each ResumePoint, in the order received:
    beginResource ───────────────────────────▶
    chunk, chunk, … ─────────────────────────▶
    endResource ─────────────────────────────▶
       ◀─────────────────────── stored | failed
  goodbye ───────────────────────────────────▶   server closes
```

The phone waits for each reply before sending more: one `need` per `manifest`, one `changes` per `manifestEnd`, and one `stored`/`failed`
per file. Only one file is ever in flight. The server MUST behave as follows.

**`hello`**
- Reply `unavailable` and close if `protocolVersion` isn't 4 or 5. The Mac says "Update Imago on this
  iPhone and on your Mac so both are on the same version." A phone older than version 3 sends no `proof`
  and also gets this reply.
- Reply `unavailable` ("Pair this iPhone with your Mac again.") and close if `deviceID` isn't paired, or
  `proof` is missing or wrong. The proof is

  ```
  binding = TLS exporter (RFC 5705), label "EXPORTER-photobackup-hello", no context, 32 bytes
  proof   = HMAC-SHA256(key = that device's key,
                        message = "photobackup-hello" 0x00 UTF-8(deviceID) 0x00 binding)
  ```

  Compare in constant time. The binding ties the proof to this TLS session, so it can't be replayed,
  and the key ties it to the device ID, so a paired phone can't write into another phone's folder.
- Reply `unavailable` and close if the backup folder can't be written (e.g. the external drive is
  unplugged). `reason` is shown to the user as is, so write it for a person.
- Otherwise reply `welcome`. If `deviceName` changed, the Mac renames the phone in its UI (not its folder).

**`manifest`** → reply `need` with every resource in the batch that isn't already stored,
in manifest order. A resource is stored if its key's text form is in the server's index.
`offset` is the size of that resource's partial file, or 0 if there isn't one.

**`beginResource`** → open the resource's partial file, creating it if needed. `size` is the full file size.
The Mac keeps partials in `<device folder>/.photobackup/partial/<sha256(key text form)>.part`.

**`chunk`** → if the partial file's length isn't `offset`, truncate it to `offset`, then append the bytes.
A chunk for a resource that wasn't begun is a protocol error, and the Mac drops the connection.

**`endResource`**
1. If the partial's length isn't the `size` from `beginResource`, delete it and reply `failed`.
2. If its SHA-256 (lowercase hex) doesn't match `sha256`, delete it and reply `failed`. The phone
   will send it from byte 0 next session. This happens when iOS renders an edit differently on a resume.
3. Otherwise move it into the library (§7), write the sidecar, record it in the index, and reply `stored`.

**`manifestEnd`** → the manifest batches since `welcome` are the phone's whole library. Save them with
`albums` as the phone's **library snapshot** (§7.5), then reply `changes` with every change still waiting
for this phone, oldest first.

**`changeReport`** → for each report, move the matching waiting change into the done list. Ignore IDs it
doesn't know (e.g. changes the user cancelled on the server after sending them).

**`goodbye`** → record the time of this device's last backup, then close.

Things the phone may do that the server must tolerate:
- Skip a resource from `need` entirely and send nothing for it (it was deleted on the phone, or iCloud
  couldn't supply it). It is asked for again next session.
- Start a file from 0 instead of the requested offset, if the file on the phone is now shorter than that offset.
- Disconnect at any point. Partial files stay and resume next time. The server should close any open
  files and save its index when a connection ends.

**The server never deletes a stored file** because of anything the phone sends.

### 6.1 Managing the phone's library

The phone is always the client, so the server can't reach it directly. Instead the server keeps a queue
of changes per phone, built from the user's choices in the server's UI, and hands it over at `manifestEnd`.

Rules for the server:
- Only offer `delete` for assets that are **fully backed up**: every resource in the phone's latest
  manifest entry for that asset is stored and checksum-verified.
- Keep a change waiting until a report for it arrives. The phone gets the same change again at each
  backup until then, and ignores ones it has already handled.
- Undoing a waiting change takes it back instead of queuing its opposite: unfavoriting a photo whose
  favorite is still waiting removes it from that change. Changes that are already true on the phone
  (as of its last `manifestEnd`) aren't queued.
- On an `applied` report, make the change to the library snapshot (§7.5) too, so it doesn't look undone
  until the next `manifestEnd`.

Rules for the phone:
- Never act on a change without the user's say-so: either they review it in the app, or they turned
  on "Apply changes from my Mac", which makes favorites and album changes as they arrive while the app
  is open. Deletions always go through iOS's own confirmation, and all approved deletions go in one
  request so iOS asks once. Deleted items go to Recently Deleted for 30 days.
- `addToAlbum` uses the user's regular album with that title, creating it if there isn't one.
  `removeFromAlbum` only works on a regular album, and fails otherwise.
- `deleteAlbum` deletes the user's regular album with that title, as Photos does: its photos and videos
  stay in the library. iOS asks the user first; declining reports `declined`. No such album: `failed`.
- Report every change it was given, applied or not, at the start of the next session, and right
  away over a live session if one is open. The server ignores a report it already has.

### 6.2 Live session (version 5)

While the app is on screen, the phone keeps a second connection to the backup service, beside any
backup, so changes made on the server reach it in about a second instead of at the next backup.

```
phone                                         server
  hello ─────────────────────────────────────▶
       ◀──────────────────────────── welcome  (or unavailable, then close)
  live ──────────────────────────────────────▶
       ◀──────────────────────────── changes  every waiting change, at once
       ◀──────────────────────────── changes  again whenever the queue changes (a change added, cancelled, withdrawn)
  changeReport ──────────────────────────────▶   as soon as the user acts; no reply
       ◀─────────────────────── thumbnailRequest
  thumbnails ────────────────────────────────▶   one or more, for the assets the phone still has
  goodbye, or the connection closes ─────────▶
```

- `changes` always carries the whole queue. The phone replaces its list with it, minus changes it has
  already handled, so a change cancelled on the server disappears from the phone too (unless the user
  has already acted on it).
- A live session isn't a backup: the server doesn't count it as one, doesn't record a backup time on
  `goodbye`, and doesn't hold off sleep for it. iOS closes it when the app leaves the screen.
- The server asks for previews of assets it has no backed-up copy of, as the user scrolls to them. It
  keeps them in its own cache, not in the backup folder, and stops using one once the real file arrives.

## 7. Files on disk

This part isn't part of the wire protocol, but the backup folder is meant to stay readable without
the app, and moving it between servers should just work. So a second implementation should match it.

### 7.1 Folders

```
<backup location>/
  .photobackup/library.json              library ID and each phone's folder (§7.6)
  <folder>/…                             folders the user makes, e.g. Tennis/Serve (§7.7)
  Recently Deleted/…                     items deleted on the server, and .imago-trash.json (§7.7)
  <device folder>/                       one per paired phone
    2026/10/2026-10-20_143012_IMG_4821.HEIC
    2026/10/2026-10-20_143012_IMG_4821.MOV
    2026/10/2026-10-20_143012_IMG_4821_edited.JPG
    2026/10/2026-10-20_143012_IMG_4821_adjustments.plist
    2026/10/2026-10-20_143012_IMG_4821.json        sidecar
    Undated/IMG_0001.JPG                            assets with no creationDate
    .photobackup/index.json                         private cache
    .photobackup/phone.json                         library snapshot (§7.5)
    .photobackup/changes.json                       changes waiting for the phone, and done ones
    .photobackup/skip.json                          keys of files the user trashed on the server
    .photobackup/partial/…                          unfinished uploads
```

**Device folder**: the phone's name at pairing time, with `/` and `:` replaced by `-` and surrounding
whitespace and dots trimmed (`iPhone` if that leaves nothing). If the name is taken, add ` 2`, ` 3`…
The folder never changes after pairing.

### 7.2 File names

Dates use the **server's local time zone** and the asset's `creationDate`.

- Directory: `YYYY/MM`, or `Undated` with no creation date.
- Prefix: `YYYY-MM-DD_HHMMSS_`, or nothing with no creation date.
- Sanitize: replace `/` and `:` with `_`. If the result is empty or starts with `.`, put `asset` in front.
- *stem* / *ext*: split at the last `.` (a leading dot doesn't count).

| kind | File name after the prefix |
|---|---|
| `photo`, `video`, `alternatePhoto`, `pairedVideo` | the resource's own sanitized `originalFilename` |
| `fullSizePhoto`, `fullSizeVideo`, `fullSizePairedVideo` | *stem of the asset's originalFilename* + `_edited.` + *ext of the resource's originalFilename* |
| `adjustmentData` | *stem of the asset's originalFilename* + `_adjustments.plist` |
| sidecar | *stem of the asset's originalFilename* + `.json` |

**Name clashes:** if a file with different contents already has the name, try `name (2).ext`,
`name (3).ext`… If a file with the **same** SHA-256 is already there, keep it and discard the upload.

After the move, set the file's creation and modification times to the asset's `creationDate`.

### 7.3 Sidecar

One JSON file per asset. It is the **source of truth**, and the index is rebuilt from sidecars.
Written pretty-printed with sorted keys and ISO 8601 dates, replaced atomically, and marked hidden
(the file system's hidden flag, not a leading dot), so Finder shows only the photos and videos.

```json
{
  "deviceID" : "6F1C…",
  "files" : [
    {
      "kind" : "photo",
      "name" : "2026-10-20_143012_IMG_4821.HEIC",
      "revision" : "original",
      "sha256" : "ba7816bf…",
      "size" : 2483112
    }
  ],
  "metadata" : { …AssetMetadata… }
}
```

**Sidecar clashes:** two assets can share a name (a photo duplicated in the Photos app keeps its filename
and date). If the sidecar path holds another asset's sidecar (a different `metadata.assetID`), try
`name (2).json`, `name (3).json`… and use the first that is free or already belongs to this asset.
A media file and its sidecar may end up with different numbers, which is fine because the sidecar
lists its files by name.

`deviceID` is the phone the asset came from, so it stays known if the files are moved out of that
phone's folder. Sidecars written before it existed leave it out; those belong to the phone whose folder
they are in. `name` is relative to the sidecar's folder. Storing a file replaces any earlier entry of the same `kind`
(a newer edit replaces the older one), and `metadata` is replaced with the latest.

### 7.4 Index

`.photobackup/index.json` maps each key's text form to where it's stored, plus each device's last
backup time. It is a private cache: other implementations can use any format, as long as they can
rebuild it by reading every sidecar. (The Mac writes dates there as seconds since 2001-01-01, so
don't parse it from another platform. Rebuild from the sidecars instead.)

### 7.5 Library snapshot and change queue

`phone.json` is the phone's library as of its last `manifestEnd`:
`{"takenAt": <date>, "entries": [<ManifestEntry>…], "albums": [<title>…]}`. Joined with the index,
it tells the server what's on the phone now and what of it is safely backed up, so the server can
suggest clean-ups (duplicates by original SHA-256, similar shots, large videos, screenshots) while the
phone is away. `changes.json` holds `{"pending": [<LibraryChange>…], "done": [{"change", "report"}…]}`.
Both are private to the server, like the index.

### 7.6 Library record

`<backup location>/.photobackup/library.json` says which library this is and which phone owns which
folder. It lives with the photos, so a library that moves to another drive or another Mac still knows
whose photos are where. Written pretty-printed with sorted keys and ISO 8601 dates, replaced atomically.

```json
{
  "createdAt" : "2026-10-20T14:30:12Z",
  "devices" : [
    { "deviceID" : "6F1C…", "folder" : "Jia's iPhone", "name" : "Jia's iPhone" }
  ],
  "libraryID" : "0B6E…"
}
```

- `libraryID` is made when the record is first written and never changes.
- A server creates the record the first time it uses a location that has none, listing its paired phones.
- When a phone is paired or first backs up here, add it if it's missing. A folder no other phone in
  the list has is used as is; otherwise add ` 2`, ` 3`… (compared without case, since macOS and Windows
  file systems usually ignore it).
- Removing a phone from a server doesn't remove it from this list, so pairing it again finds its folder.
- Device keys are **never** written here. A phone pairs again with each server.
- A server that can't read the record must not overwrite it.

### 7.7 Folders

The user's own folders sit at the top of the backup location, next to the device folders, such as
one for tennis videos, nested to any depth. A top-level folder is the user's unless it's a device
folder (any listed in `library.json`, removed phones included) or Recently Deleted. Earlier versions
kept them in `Folders/`; the Mac moves them up a level and removes `Folders` once empty. An asset moved there takes all its files and its sidecar along, flat in the folder, keeping
their names (numbered on a clash, as in §7.2). Its sidecar's `deviceID` says which phone it came from.

Moved files stay in their phone's index, so the phone isn't asked for them again. The Mac stores their
paths relative to the device folder, so they start with `../` (e.g. `../Tennis/IMG_4821.MOV`). When rebuilding an index from
sidecars, read the device folder and every sidecar elsewhere in the backup location (Folders,
Recently Deleted) whose `deviceID` is that phone.

**Recently Deleted** is a folder in the backup location (`Recently Deleted/` unless the user chose
another one inside it, outside Folders and the device folders). Deleting moves an asset there exactly
like moving it into a Folder: its files and sidecar go along and its index paths follow, so the phone
isn't asked for it again. `Recently Deleted/.imago-trash.json` records, for each item, when it was
deleted and where it came from, so it can be put back:

```json
{"entries": {"<deviceID>/<assetID>": {"deletedAt": "2026-10-24T09:00:00Z", "from": {"folder": {"_0": "Tennis"}}},
             "file:holiday.mov":    {"deletedAt": "2026-10-24T09:01:00Z", "from": {"phoneFolder": {}}}}}
```

Keys are `deviceID/assetID` for a phone's asset and `file:<name>` for other files. `from` is
`{"phoneFolder":{}}` (the device's dated folders) or `{"folder":{"_0":"<path in Folders>"}}`.
Items are deleted for good after a number of days the user chooses (30 by default); deleting for good
removes the files and sidecar and adds the keys to `skip.json` (below).

A Folder can also hold files that never came from a phone (AirDrop, Finder). They have no sidecar
and are shown as they are.

When the user deletes a file for good on the server, its keys go into the device's `skip.json`
(a JSON array of key text forms), and the server leaves them out of `need`, even though the phone still
has them. Without this, the next backup would bring the file straight back.

## 8. Versioning and changes

The server accepts versions 4 to 6; the phone sends 6. A version-4 phone backs up as before and never
opens a live session; a version-5 phone is never sent `deleteAlbum`. Older versions are refused. From version 4, both sides
skip control messages whose names they don't know (§4) instead of dropping the connection. So a later
message the other side can ignore can be added without a version bump, and a Windows server can lag
behind the Mac by a release. A change the other side must understand still needs a new version.

## 9. History

- **Version 6:** the `deleteAlbum` change.
- **Version 5:** live sessions (`live`), with `changes` pushed whenever the queue changes and
  `changeReport` sent as soon as the user acts; previews (`thumbnailRequest`, `thumbnails`).
- **Version 4:** the phone sends `manifestEnd` with its album list, and the server replies `changes`;
  the phone sends `changeReport`. Metadata gains `subtypes` and `burstID`. Unknown messages are skipped.
- **Version 3:** `hello` carries `proof`, so the server checks which phone it's talking to, not just that
  it holds some paired key. Sidecars whose names clash get numbered names. A version mismatch now
  says "update the app" instead of "pair again".
- **Version 2:** each phone has its own key, issued at pairing.
