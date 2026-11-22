# App Review notes

## iPhone/iPad app (Imago: Back Up to Your Mac)

Imago backs up the photos and videos on an iPhone or iPad to the user's own Mac, over their local Wi-Fi. There is no server and no account: the iPhone app works only with the free Mac app, "Imago: iPhone Photo Backup", which we are submitting at the same time.

HOW TO TEST
1. On a Mac (macOS 15 or later) on the same Wi-Fi network as the test iPhone, install and open Imago for Mac. It lives in the menu bar and opens a window.
2. On the Mac, click "Add iPhone". A QR code appears.
3. On the iPhone, open Imago, tap "Pair with Mac", scan the QR code with the in-app camera, then tap Pair. Pairing uses the camera: the Mac's "Copy Link" button is only for the iOS Simulator, which has no camera. The attached video was recorded in the iOS Simulator, which has no camera, so its scanning step is simulated.
4. Tap "Back Up Now" and allow Photos access. Photos appear in the Mac window under Library and under the iPhone's own row in the sidebar.
5. Free up space: on the Mac, open the iPhone's row > Free Up Space, select duplicates or large videos and press Delete. The iPhone asks for confirmation with the standard iOS dialog, and items go to Recently Deleted. Only items with a verified copy on the Mac can be deleted.

A short video of pairing and a first backup is attached.

IN-APP PURCHASES
Every feature is free for 7 days, starting when the user taps Start or makes the first backup. After that, backing up new photos needs a one-time, non-consumable purchase:
- com.ljworkshop.imago.unlock ($14.99): one person, all their iPhones and iPads. Family Sharing off.
- com.ljworkshop.imago.family ($39.99): up to 6 people. Family Sharing on.
- com.ljworkshop.imago.familyupgrade ($24.99): Family Sharing on. Shown only to people who already own the $14.99 unlock, so the upgrade costs the difference. To see it, buy the unlock first in the sandbox.
The purchase screen opens from the card on the main screen ("Try Imago free for 7 days" > Start begins the trial; during the trial the card's "Unlock" button opens the purchase sheet), and by itself when a backup is attempted after the trial ends. "Restore Purchases" is on the same screen. Restoring photos from the Mac back to the iPhone, and everything already on the Mac, stay free with no purchase.
No subscription, no external payment links.

PERMISSIONS
- Photos: to copy the library to the Mac, and to apply deletions/favourites the user makes from the Mac (each deletion is confirmed by iOS).
- Local Network: to find the paired Mac with Bonjour (_photobackup._tcp).
- Camera: only to scan the pairing QR code.
- Background processing: overnight backups while charging (BGProcessingTask).

ENCRYPTION
The connection uses TLS 1.3 with a pre-shared key via Apple's Network framework only. No proprietary encryption. ITSAppUsesNonExemptEncryption is NO.

## Mac app (Imago: iPhone Photo Backup)

Free, no in-app purchases. It receives backups from the Imago iPhone/iPad app over the local network and saves them as plain files (original photos and videos, in dated folders) in a folder the user chooses, by default ~/Pictures/Photo Backup. The menu bar item shows backup status. To test, follow the steps above; without a paired iPhone the window shows an empty library and the "Add iPhone" pairing sheet.

Sandbox entitlements: com.apple.security.network.server is required because this Mac app is the receiving end of every backup. It opens a listener (Network framework, NWListener, TLS 1.3 with a pre-shared key) and advertises it on the local network with Bonjour (_photobackup._tcp); the paired iPhone/iPad app finds it and connects in to send photos and videos. Without it no backup can be received. It accepts only devices paired by scanning the QR code shown on the Mac. Also: network client, Pictures folder read-write (default backup location), user-selected files read-write plus app-scoped bookmarks (backup folder on another drive).
