# App Store listing for Imago, both apps, ten languages.
# Run: python3 docs/app-store/listing.py  -> checks lengths, writes listing.json next to this file.
import json, os

SUPPORT = "https://ljworkshop.com/imago/support/"
MARKETING = "https://ljworkshop.com/imago/"

L = {}

# ---------------------------------------------------------------- English
L["en-US"] = dict(
ios_name="Imago: Back Up to Your Mac",
ios_sub="Free up space without iCloud",
ios_promo="iPhone storage full? Back up every photo and video to your own Mac over Wi-Fi, then free up space safely. No cloud, no subscription.",
ios_kw="photo,backup,storage,full,free up space,transfer,icloud,alternative,wifi,video,local,offline,mac",
ios_desc="""iPhone storage full? Imago backs up every photo and video from your iPhone to your own Mac, automatically, usually overnight while the phone charges, over your own Wi-Fi. No cloud, no account, no subscription.

Requires the free Imago app on a Mac.

YOUR PHOTOS STAY HOME
Photos go straight from your iPhone to your Mac, encrypted with a key made when you pair them. They never pass through a server: Imago doesn't have one.

FREE UP YOUR IPHONE, SAFELY
Nothing is removed from your iPhone until the Mac holds a verified copy. On the Mac, Imago finds exact duplicates, similar shots, bursts, large videos and screenshots, and you approve every deletion on the iPhone. Deleted photos go to Recently Deleted, as always.

PLAIN FILES ON YOUR DRIVE
Originals, Live Photos and edits are saved as ordinary files in dated folders, on your Mac or any drive you choose. Open them without Imago, today or in twenty years.

HOW IT WORKS
• Pair once by scanning the code on your Mac.
• Leave the iPhone charging and Imago backs up new photos, usually overnight. Or open it to back up now.
• An interrupted backup picks up where it stopped.
• Originals stored in iCloud Photos are downloaded and backed up too.
• Photos you delete on the iPhone stay in the backup until you decide.
• Put any photo back on your iPhone from the Mac, with its date, place and albums.

PRICE
Try every feature free for 7 days. After that, a one-time purchase keeps backing up new photos and videos: Imago, for you on all your iPhones and iPads, or Imago Family, for up to 6 people with Family Sharing. No subscription. Restoring photos is always free, and your backups are plain files you keep, with or without the app.""",
mac_name="Imago: iPhone Photo Backup",
mac_sub="Your photos, on your own drive",
mac_promo="Back up your iPhone's photos to your own Mac over Wi-Fi, then free up space on the phone safely. No cloud, no subscription. The Mac app is free.",
mac_kw="photo backup,iphone,transfer,storage,free up space,duplicates,icloud,alternative,wifi,video,local",
mac_desc="""Imago backs up the photos and videos from your iPhone to your Mac, automatically, usually overnight, over your own Wi-Fi. No cloud, no account, no subscription. The Mac app is free.

Use it with the Imago app on your iPhone or iPad.

YOUR PHOTOS STAY HOME
Photos go straight from your iPhone to your Mac, encrypted with a key made when you pair them. They never pass through a server: Imago doesn't have one.

FREE UP YOUR IPHONE, SAFELY
See each iPhone's library on the Mac, laid out like Photos. Imago finds exact duplicates, similar shots and bursts, large videos and screenshots. Choose what to remove: the iPhone deletes only what the Mac holds a verified copy of, and only after you confirm on the phone.

PLAIN FILES ON YOUR DRIVE
Every original, Live Photo and edit lands in dated folders on your Mac, an external drive or a network drive. Open them in Finder or any app, without Imago, today or in twenty years.

ON THE MAC
• Library, Places, On This Day and Large Files across all your iPhones
• Folders that are real folders on the drive
• A viewer and editor for photos and videos
• Several iPhones, each in its own folder
• Photos deleted on an iPhone stay in the backup until you decide
• Put photos back on the iPhone, with their dates, places and albums
• Lives in the menu bar

PRICE
The Mac app is free. On iPhone and iPad, try every feature free for 7 days, then a one-time purchase keeps backing up new photos. No subscription. Restoring photos is always free, and your backups are plain files you keep, with or without the app.""",
)

# ---------------------------------------------------------------- German
L["de-DE"] = dict(
ios_name="Imago: Backup auf deinen Mac",
ios_sub="Speicher frei, ohne iCloud",
ios_promo="iPhone-Speicher voll? Sichere alle Fotos und Videos über dein WLAN auf deinen eigenen Mac und gib dann sicher Platz frei. Ohne Cloud, ohne Abo.",
ios_kw="foto,backup,speicher,voll,platz,freigeben,übertragen,icloud,alternative,wlan,video,lokal,mac",
ios_desc="""iPhone-Speicher voll? Imago sichert alle Fotos und Videos von deinem iPhone auf deinem eigenen Mac – automatisch, meist nachts beim Laden, über dein eigenes WLAN. Ohne Cloud, ohne Account, ohne Abo.

Erfordert die kostenlose Imago-App auf einem Mac.

DEINE FOTOS BLEIBEN ZU HAUSE
Fotos gehen direkt vom iPhone auf deinen Mac, verschlüsselt mit einem Schlüssel, der beim Koppeln entsteht. Sie laufen nie über einen Server: Imago hat keinen.

PLATZ AUF DEM IPHONE, SICHER
Vom iPhone wird nichts entfernt, bevor der Mac eine geprüfte Kopie hat. Auf dem Mac findet Imago exakte Duplikate, ähnliche Aufnahmen, Serienbilder, große Videos und Bildschirmfotos, und du bestätigst jedes Löschen auf dem iPhone. Gelöschte Fotos landen wie immer in „Zuletzt gelöscht“.

NORMALE DATEIEN AUF DEINEM LAUFWERK
Originale, Live Photos und Bearbeitungen werden als normale Dateien in Ordnern nach Datum gespeichert, auf dem Mac oder einem Laufwerk deiner Wahl. Du öffnest sie auch ohne Imago, heute oder in zwanzig Jahren.

SO FUNKTIONIERT ES
• Einmal koppeln: den Code auf dem Mac scannen.
• Lass das iPhone laden, und Imago sichert neue Fotos, meist über Nacht. Oder öffne die App für ein Backup sofort.
• Ein unterbrochenes Backup macht dort weiter, wo es aufgehört hat.
• Originale in iCloud-Fotos werden geladen und ebenfalls gesichert.
• Fotos, die du auf dem iPhone löschst, bleiben im Backup, bis du entscheidest.
• Hol jedes Foto vom Mac zurück aufs iPhone, mit Datum, Ort und Alben.

PREIS
Teste 7 Tage lang alle Funktionen gratis. Danach sichert ein einmaliger Kauf weiterhin neue Fotos und Videos: Imago für dich auf all deinen iPhones und iPads oder Imago Familie für bis zu 6 Personen mit der Familienfreigabe. Kein Abo. Fotos wiederherstellen ist immer kostenlos, und deine Backups sind normale Dateien, die du behältst – mit oder ohne App.""",
mac_name="Imago: iPhone-Fotobackup",
mac_sub="Fotos auf deinem eigenen Mac",
mac_promo="Sichere die Fotos deines iPhones über dein WLAN auf deinem eigenen Mac und gib dann sicher Platz auf dem iPhone frei. Ohne Cloud, ohne Abo. Die Mac-App ist gratis.",
mac_kw="fotobackup,iphone,übertragen,speicher,platz freigeben,duplikate,icloud,alternative,wlan,video",
mac_desc="""Imago sichert die Fotos und Videos deines iPhones auf deinem Mac – automatisch, meist über Nacht, über dein eigenes WLAN. Ohne Cloud, ohne Account, ohne Abo. Die Mac-App ist kostenlos.

Zusammen mit der Imago-App auf deinem iPhone oder iPad.

DEINE FOTOS BLEIBEN ZU HAUSE
Fotos gehen direkt vom iPhone auf deinen Mac, verschlüsselt mit einem Schlüssel, der beim Koppeln entsteht. Sie laufen nie über einen Server: Imago hat keinen.

PLATZ AUF DEM IPHONE, SICHER
Sieh die Mediathek jedes iPhones auf dem Mac, aufgebaut wie in Fotos. Imago findet exakte Duplikate, ähnliche Aufnahmen und Serien, große Videos und Bildschirmfotos. Du wählst aus, was weg soll: Das iPhone löscht nur, wovon der Mac eine geprüfte Kopie hat, und erst nach deiner Bestätigung auf dem iPhone.

NORMALE DATEIEN AUF DEINEM LAUFWERK
Jedes Original, jedes Live Photo und jede Bearbeitung landet in Ordnern nach Datum, auf dem Mac, einem externen Laufwerk oder einem Netzlaufwerk. Öffne sie im Finder oder in jeder App, ohne Imago, heute oder in zwanzig Jahren.

AUF DEM MAC
• Mediathek, Orte, An diesem Tag und Große Dateien über alle iPhones
• Ordner, die echte Ordner auf dem Laufwerk sind
• Ein Viewer und Editor für Fotos und Videos
• Mehrere iPhones, jedes in seinem eigenen Ordner
• Auf dem iPhone gelöschte Fotos bleiben im Backup, bis du entscheidest
• Fotos zurück aufs iPhone, mit Datum, Ort und Alben
• Lebt in der Menüleiste

PREIS
Die Mac-App ist kostenlos. Auf iPhone und iPad testest du 7 Tage lang alle Funktionen gratis, danach sichert ein einmaliger Kauf weiterhin neue Fotos. Kein Abo. Fotos wiederherstellen ist immer kostenlos, und deine Backups sind normale Dateien, die du behältst – mit oder ohne App.""",
)

# ---------------------------------------------------------------- Spanish
L["es-ES"] = dict(
ios_name="Imago: Copia en tu Mac",
ios_sub="Libera espacio sin iCloud",
ios_promo="¿Almacenamiento del iPhone lleno? Copia todas tus fotos y vídeos en tu propio Mac por wifi y libera espacio con seguridad. Sin nube y sin suscripción.",
ios_kw="foto,copia,seguridad,almacenamiento,lleno,liberar espacio,transferir,icloud,wifi,vídeo,local,mac",
ios_desc="""¿Almacenamiento del iPhone lleno? Imago hace una copia de todas las fotos y vídeos de tu iPhone en tu propio Mac, de forma automática, normalmente por la noche mientras se carga, por tu propia wifi. Sin nube, sin cuenta y sin suscripción.

Requiere la app gratuita Imago en un Mac.

TUS FOTOS SE QUEDAN EN CASA
Las fotos van directamente de tu iPhone a tu Mac, cifradas con una clave creada al enlazarlos. Nunca pasan por un servidor: Imago no tiene ninguno.

LIBERA ESPACIO EN EL IPHONE, CON SEGURIDAD
No se elimina nada del iPhone hasta que el Mac tiene una copia verificada. En el Mac, Imago encuentra duplicados exactos, fotos parecidas, ráfagas, vídeos grandes y capturas de pantalla, y tú apruebas cada eliminación en el iPhone. Las fotos eliminadas van a Eliminado, como siempre.

ARCHIVOS NORMALES EN TU DISCO
Los originales, las Live Photos y las ediciones se guardan como archivos normales en carpetas por fecha, en tu Mac o en el disco que elijas. Ábrelos sin Imago, hoy o dentro de veinte años.

CÓMO FUNCIONA
• Enlázalos una vez escaneando el código del Mac.
• Deja el iPhone cargando e Imago copia las fotos nuevas, normalmente por la noche. O ábrelo para hacer la copia ya.
• Una copia interrumpida sigue donde se quedó.
• Los originales guardados en Fotos de iCloud también se descargan y se copian.
• Las fotos que eliminas en el iPhone siguen en la copia hasta que tú decidas.
• Devuelve cualquier foto al iPhone desde el Mac, con su fecha, lugar y álbumes.

PRECIO
Prueba todas las funciones gratis durante 7 días. Después, una compra única sigue haciendo copia de las fotos y vídeos nuevos: Imago, para ti en todos tus iPhone y iPad, o Imago Familia, para hasta 6 personas con En familia. Sin suscripción. Restaurar fotos siempre es gratis, y tus copias son archivos normales que conservas, con o sin la app.""",
mac_name="Imago: Copia de fotos iPhone",
mac_sub="Tus fotos, en tu propio disco",
mac_promo="Copia las fotos de tu iPhone en tu propio Mac por wifi y libera espacio en el iPhone con seguridad. Sin nube y sin suscripción. La app para Mac es gratis.",
mac_kw="copia de fotos,iphone,transferir,almacenamiento,liberar espacio,duplicados,icloud,wifi,vídeo",
mac_desc="""Imago hace una copia de las fotos y vídeos de tu iPhone en tu Mac, de forma automática, normalmente por la noche, por tu propia wifi. Sin nube, sin cuenta y sin suscripción. La app para Mac es gratis.

Úsala con la app Imago en tu iPhone o iPad.

TUS FOTOS SE QUEDAN EN CASA
Las fotos van directamente de tu iPhone a tu Mac, cifradas con una clave creada al enlazarlos. Nunca pasan por un servidor: Imago no tiene ninguno.

LIBERA ESPACIO EN EL IPHONE, CON SEGURIDAD
Ve la fototeca de cada iPhone en el Mac, organizada como en Fotos. Imago encuentra duplicados exactos, fotos parecidas y ráfagas, vídeos grandes y capturas de pantalla. Tú eliges qué quitar: el iPhone solo elimina aquello de lo que el Mac tiene una copia verificada, y solo después de que lo confirmes en el teléfono.

ARCHIVOS NORMALES EN TU DISCO
Cada original, Live Photo y edición se guarda en carpetas por fecha, en tu Mac, en un disco externo o en un disco de red. Ábrelos en el Finder o en cualquier app, sin Imago, hoy o dentro de veinte años.

EN EL MAC
• Fototeca, Lugares, Un día como hoy y Archivos grandes de todos tus iPhone
• Carpetas que son carpetas reales en el disco
• Un visor y editor de fotos y vídeos
• Varios iPhone, cada uno en su carpeta
• Las fotos eliminadas en un iPhone siguen en la copia hasta que decidas
• Devuelve fotos al iPhone con su fecha, lugar y álbumes
• Vive en la barra de menús

PRECIO
La app para Mac es gratis. En iPhone y iPad, prueba todas las funciones gratis durante 7 días; después, una compra única sigue copiando las fotos nuevas. Sin suscripción. Restaurar fotos siempre es gratis, y tus copias son archivos normales que conservas, con o sin la app.""",
)

# ---------------------------------------------------------------- French
L["fr-FR"] = dict(
ios_name="Imago : Sauvegarde sur Mac",
ios_sub="Libérer l’espace sans iCloud",
ios_promo="Stockage de l’iPhone saturé ? Sauvegardez photos et vidéos sur votre propre Mac via votre Wi-Fi, puis libérez de l’espace en toute sécurité. Sans cloud ni abonnement.",
ios_kw="photo,sauvegarde,stockage,saturé,libérer espace,transfert,icloud,alternative,wifi,vidéo,local,mac",
ios_desc="""Stockage de l’iPhone saturé ? Imago sauvegarde toutes les photos et vidéos de votre iPhone sur votre propre Mac, automatiquement, généralement la nuit pendant la recharge, via votre propre Wi-Fi. Sans cloud, sans compte, sans abonnement.

Nécessite l’app gratuite Imago sur un Mac.

VOS PHOTOS RESTENT CHEZ VOUS
Les photos vont directement de l’iPhone à votre Mac, chiffrées avec une clé créée lors du jumelage. Elles ne passent jamais par un serveur : Imago n’en a pas.

LIBÉREZ VOTRE IPHONE, EN TOUTE SÉCURITÉ
Rien n’est supprimé de l’iPhone tant que le Mac n’en a pas une copie vérifiée. Sur le Mac, Imago trouve les doublons exacts, les photos similaires, les rafales, les grosses vidéos et les captures d’écran, et vous approuvez chaque suppression sur l’iPhone. Les photos supprimées vont dans Suppressions récentes, comme toujours.

DES FICHIERS ORDINAIRES SUR VOTRE DISQUE
Originaux, Live Photos et retouches sont enregistrés comme des fichiers ordinaires, dans des dossiers datés, sur votre Mac ou le disque de votre choix. Ouvrez-les sans Imago, aujourd’hui ou dans vingt ans.

COMMENT ÇA MARCHE
• Jumelez une fois en scannant le code affiché sur le Mac.
• Laissez l’iPhone en charge : Imago sauvegarde les nouvelles photos, généralement la nuit. Ou ouvrez l’app pour sauvegarder tout de suite.
• Une sauvegarde interrompue reprend là où elle s’était arrêtée.
• Les originaux stockés dans Photos iCloud sont aussi téléchargés et sauvegardés.
• Les photos supprimées sur l’iPhone restent dans la sauvegarde jusqu’à votre décision.
• Remettez n’importe quelle photo sur l’iPhone depuis le Mac, avec sa date, son lieu et ses albums.

PRIX
Essayez toutes les fonctionnalités gratuitement pendant 7 jours. Ensuite, un achat unique continue de sauvegarder les nouvelles photos et vidéos : Imago, pour vous sur tous vos iPhone et iPad, ou Imago Famille, pour 6 personnes maximum avec le Partage familial. Aucun abonnement. Restaurer des photos est toujours gratuit, et vos sauvegardes sont des fichiers ordinaires que vous gardez, avec ou sans l’app.""",
mac_name="Imago : Sauvegarde d’iPhone",
mac_sub="Vos photos, sur votre disque",
mac_promo="Sauvegardez les photos de votre iPhone sur votre propre Mac via votre Wi-Fi, puis libérez l’iPhone en toute sécurité. Sans cloud ni abonnement. App Mac gratuite.",
mac_kw="sauvegarde photo,iphone,transfert,stockage,libérer espace,doublons,icloud,alternative,wifi,vidéo",
mac_desc="""Imago sauvegarde les photos et vidéos de votre iPhone sur votre Mac, automatiquement, généralement la nuit, via votre propre Wi-Fi. Sans cloud, sans compte, sans abonnement. L’app Mac est gratuite.

À utiliser avec l’app Imago sur votre iPhone ou iPad.

VOS PHOTOS RESTENT CHEZ VOUS
Les photos vont directement de l’iPhone à votre Mac, chiffrées avec une clé créée lors du jumelage. Elles ne passent jamais par un serveur : Imago n’en a pas.

LIBÉREZ VOTRE IPHONE, EN TOUTE SÉCURITÉ
Voyez la photothèque de chaque iPhone sur le Mac, organisée comme dans Photos. Imago trouve les doublons exacts, les photos similaires et les rafales, les grosses vidéos et les captures d’écran. Vous choisissez quoi retirer : l’iPhone ne supprime que ce dont le Mac a une copie vérifiée, et seulement après votre confirmation sur le téléphone.

DES FICHIERS ORDINAIRES SUR VOTRE DISQUE
Chaque original, Live Photo et retouche arrive dans des dossiers datés, sur votre Mac, un disque externe ou un disque réseau. Ouvrez-les dans le Finder ou n’importe quelle app, sans Imago, aujourd’hui ou dans vingt ans.

SUR LE MAC
• Photothèque, Lieux, En ce jour et Gros fichiers pour tous vos iPhone
• Des dossiers qui sont de vrais dossiers sur le disque
• Un visualiseur et éditeur de photos et de vidéos
• Plusieurs iPhone, chacun dans son dossier
• Les photos supprimées sur un iPhone restent dans la sauvegarde jusqu’à votre décision
• Remettez des photos sur l’iPhone, avec leur date, leur lieu et leurs albums
• Dans la barre des menus

PRIX
L’app Mac est gratuite. Sur iPhone et iPad, essayez toutes les fonctionnalités gratuitement pendant 7 jours, puis un achat unique continue de sauvegarder les nouvelles photos. Aucun abonnement. Restaurer des photos est toujours gratuit, et vos sauvegardes sont des fichiers ordinaires que vous gardez, avec ou sans l’app.""",
)

# ---------------------------------------------------------------- Italian
L["it"] = dict(
ios_name="Imago: Backup sul tuo Mac",
ios_sub="Libera spazio senza iCloud",
ios_promo="Spazio dell’iPhone esaurito? Fai il backup di foto e video sul tuo Mac tramite la tua rete Wi-Fi, poi libera spazio in sicurezza. Niente cloud, niente abbonamento.",
ios_kw="foto,backup,spazio,pieno,liberare spazio,trasferire,icloud,alternativa,wifi,video,locale,mac",
ios_desc="""Spazio dell’iPhone esaurito? Imago fa il backup di tutte le foto e i video dell’iPhone sul tuo Mac, in automatico, di solito di notte mentre è in carica, tramite la tua rete Wi-Fi. Niente cloud, niente account, niente abbonamento.

Richiede l’app gratuita Imago su un Mac.

LE TUE FOTO RESTANO A CASA
Le foto vanno direttamente dall’iPhone al Mac, cifrate con una chiave creata quando li abbini. Non passano mai da un server: Imago non ne ha.

LIBERA L’IPHONE, IN SICUREZZA
Dall’iPhone non viene rimosso nulla finché il Mac non ne ha una copia verificata. Sul Mac, Imago trova duplicati esatti, scatti simili, raffiche, video grandi e istantanee schermo, e tu approvi ogni eliminazione sull’iPhone. Le foto eliminate finiscono in Eliminati di recente, come sempre.

FILE NORMALI SUL TUO DISCO
Originali, Live Photo e modifiche vengono salvati come file normali in cartelle per data, sul Mac o sul disco che scegli. Aprili senza Imago, oggi o tra vent’anni.

COME FUNZIONA
• Abbina una volta scansionando il codice sul Mac.
• Lascia l’iPhone in carica e Imago salva le nuove foto, di solito di notte. Oppure aprilo per fare subito il backup.
• Un backup interrotto riprende da dove si era fermato.
• Anche gli originali in Foto di iCloud vengono scaricati e salvati.
• Le foto che elimini sull’iPhone restano nel backup finché non decidi tu.
• Riporta qualsiasi foto sull’iPhone dal Mac, con data, luogo e album.

PREZZO
Prova tutte le funzioni gratis per 7 giorni. Poi un acquisto una tantum continua a fare il backup di nuove foto e video: Imago, per te su tutti i tuoi iPhone e iPad, oppure Imago Famiglia, per un massimo di 6 persone con In famiglia. Nessun abbonamento. Ripristinare le foto è sempre gratis, e i tuoi backup sono file normali che conservi, con o senza l’app.""",
mac_name="Imago: Backup foto iPhone",
mac_sub="Le tue foto, sul tuo disco",
mac_promo="Fai il backup delle foto dell’iPhone sul tuo Mac tramite la tua rete Wi-Fi, poi libera l’iPhone in sicurezza. Niente cloud, niente abbonamento. L’app per Mac è gratis.",
mac_kw="backup foto,iphone,trasferire,spazio,liberare spazio,duplicati,icloud,alternativa,wifi,video",
mac_desc="""Imago fa il backup delle foto e dei video dell’iPhone sul tuo Mac, in automatico, di solito di notte, tramite la tua rete Wi-Fi. Niente cloud, niente account, niente abbonamento. L’app per Mac è gratis.

Si usa con l’app Imago su iPhone o iPad.

LE TUE FOTO RESTANO A CASA
Le foto vanno direttamente dall’iPhone al Mac, cifrate con una chiave creata quando li abbini. Non passano mai da un server: Imago non ne ha.

LIBERA L’IPHONE, IN SICUREZZA
Guarda la libreria di ogni iPhone sul Mac, organizzata come in Foto. Imago trova duplicati esatti, scatti simili e raffiche, video grandi e istantanee schermo. Scegli cosa rimuovere: l’iPhone elimina solo ciò di cui il Mac ha una copia verificata, e solo dopo la tua conferma sul telefono.

FILE NORMALI SUL TUO DISCO
Ogni originale, Live Photo e modifica finisce in cartelle per data, sul Mac, su un disco esterno o di rete. Aprili nel Finder o in qualsiasi app, senza Imago, oggi o tra vent’anni.

SUL MAC
• Libreria, Luoghi, Accadde oggi e File grandi di tutti i tuoi iPhone
• Cartelle che sono vere cartelle sul disco
• Un visore ed editor per foto e video
• Più iPhone, ognuno nella sua cartella
• Le foto eliminate su un iPhone restano nel backup finché non decidi tu
• Riporta le foto sull’iPhone, con data, luogo e album
• Vive nella barra dei menu

PREZZO
L’app per Mac è gratis. Su iPhone e iPad prova tutte le funzioni gratis per 7 giorni, poi un acquisto una tantum continua a salvare le nuove foto. Nessun abbonamento. Ripristinare le foto è sempre gratis, e i tuoi backup sono file normali che conservi, con o senza l’app.""",
)

# ---------------------------------------------------------------- Japanese
L["ja"] = dict(
ios_name="Imago：Macに写真をバックアップ",
ios_sub="iCloudなしでiPhoneの空きを確保",
ios_promo="iPhoneのストレージがいっぱい？ 写真とビデオを自宅のWi-Fiで自分のMacにバックアップし、安全に空き容量を作れます。クラウドもサブスクリプションも不要です。",
ios_kw="写真,バックアップ,ストレージ,容量不足,空き容量,転送,iCloud,代わり,Wi-Fi,ビデオ,ローカル,Mac,整理",
ios_desc="""iPhoneのストレージがいっぱいですか？ Imagoは、iPhoneのすべての写真とビデオを自分のMacへ自動でバックアップします。多くの場合、充電中の夜間に、自宅のWi-Fiで。クラウドもアカウントもサブスクリプションも不要です。

Mac用の無料アプリ「Imago」が必要です。

写真は家から出ません
写真はiPhoneからMacへ直接送られ、ペアリング時に作られる鍵で暗号化されます。サーバを経由することはありません。Imagoにはサーバがないからです。

iPhoneの空きを、安全に
Macに検証済みのコピーができるまで、iPhoneからは何も削除されません。Mac上でImagoが完全な重複、似た写真、バースト、大きなビデオ、スクリーンショットを見つけ、削除はすべてiPhoneで確認してから行われます。削除した写真は、いつもどおり「最近削除した項目」に入ります。

ドライブには普通のファイルで
オリジナル、Live Photos、編集後の写真は、日付ごとのフォルダに普通のファイルとして保存されます。保存先はMacでも、好きなドライブでもかまいません。今日でも20年後でも、Imagoなしで開けます。

しくみ
• Macに表示されるコードを一度スキャンしてペアリング。
• iPhoneを充電しておけば、新しい写真を多くの場合夜間にバックアップ。今すぐバックアップしたいときはアプリを開くだけ。
• 中断したバックアップは、止まったところから再開。
• iCloud写真にあるオリジナルもダウンロードしてバックアップ。
• iPhoneで削除した写真は、あなたが決めるまでバックアップに残ります。
• Macから写真をiPhoneに戻すことも。日付、場所、アルバムもそのままです。

価格
7日間、すべての機能を無料でお試しいただけます。その後は一度だけの購入で、新しい写真とビデオのバックアップを続けられます。あなたのすべてのiPhoneとiPadで使える「Imago」、またはファミリー共有で最大6人まで使える「Imago ファミリー」。サブスクリプションではありません。写真の復元はいつでも無料。バックアップは普通のファイルなので、アプリがあってもなくても手元に残ります。""",
mac_name="Imago：iPhone写真バックアップ",
mac_sub="写真を自分のドライブに",
mac_promo="iPhoneの写真を自宅のWi-Fiで自分のMacにバックアップし、iPhoneの空き容量を安全に作れます。クラウドもサブスクリプションも不要。Mac版は無料です。",
mac_kw="写真バックアップ,iPhone,転送,ストレージ,空き容量,重複,iCloud,代わり,Wi-Fi,ビデオ,ローカル,整理",
mac_desc="""Imagoは、iPhoneの写真とビデオをMacへ自動でバックアップします。多くの場合夜間に、自宅のWi-Fiで。クラウドもアカウントもサブスクリプションも不要です。Mac版は無料です。

iPhoneまたはiPadのImagoアプリと一緒に使います。

写真は家から出ません
写真はiPhoneからMacへ直接送られ、ペアリング時に作られる鍵で暗号化されます。サーバを経由することはありません。Imagoにはサーバがないからです。

iPhoneの空きを、安全に
各iPhoneのライブラリを、写真アプリのような画面でMacに表示。完全な重複、似た写真やバースト、大きなビデオ、スクリーンショットを見つけます。削除するものを選んでも、iPhoneが削除するのはMacに検証済みのコピーがあるものだけ。しかもiPhoneで確認してからです。

ドライブには普通のファイルで
すべてのオリジナル、Live Photos、編集後の写真が、Mac、外付けドライブ、またはネットワークドライブ上の日付ごとのフォルダに保存されます。Finderやどのアプリでも、Imagoなしで開けます。今日でも20年後でも。

Macでできること
• すべてのiPhoneの写真を、ライブラリ、撮影地、この日、大きなファイルで表示
• ドライブ上の本物のフォルダとして使えるフォルダ
• 写真とビデオのビューア兼エディタ
• 複数のiPhoneを、それぞれ専用のフォルダに
• iPhoneで削除した写真も、あなたが決めるまでバックアップに保持
• 写真をiPhoneへ戻す。日付、場所、アルバムもそのまま
• メニューバーに常駐

価格
Mac版は無料です。iPhoneとiPadでは7日間すべての機能を無料で試せ、その後は一度だけの購入で新しい写真のバックアップを続けられます。サブスクリプションではありません。写真の復元はいつでも無料。バックアップは普通のファイルなので、アプリがあってもなくても手元に残ります。""",
)

# ---------------------------------------------------------------- Korean
L["ko"] = dict(
ios_name="Imago: Mac에 사진 백업",
ios_sub="iCloud 없이 iPhone 공간 확보",
ios_promo="iPhone 저장 공간이 가득 찼나요? 모든 사진과 비디오를 집 Wi-Fi로 내 Mac에 백업하고, 안전하게 공간을 확보하세요. 클라우드도 구독도 없습니다.",
ios_kw="사진,백업,저장 공간,용량 부족,공간 확보,전송,iCloud,대안,Wi-Fi,비디오,로컬,Mac,정리",
ios_desc="""iPhone 저장 공간이 가득 찼나요? Imago는 iPhone의 모든 사진과 비디오를 내 Mac에 자동으로 백업합니다. 대개 충전 중인 밤에, 집의 Wi-Fi로. 클라우드도, 계정도, 구독도 없습니다.

Mac용 무료 Imago 앱이 필요합니다.

사진은 집 밖으로 나가지 않습니다
사진은 iPhone에서 Mac으로 바로 전송되며, 페어링할 때 만들어진 키로 암호화됩니다. 서버를 거치지 않습니다. Imago에는 서버가 없으니까요.

안전하게 iPhone 공간 확보
Mac에 검증된 사본이 생기기 전에는 iPhone에서 아무것도 지우지 않습니다. Mac에서 Imago가 완전히 같은 중복 사진, 비슷한 사진, 연속 촬영, 큰 비디오, 스크린샷을 찾아 주고, 모든 삭제는 iPhone에서 직접 승인합니다. 삭제한 사진은 언제나처럼 최근 삭제된 항목으로 갑니다.

드라이브에는 일반 파일로
원본, Live Photo, 편집본이 날짜별 폴더에 일반 파일로 저장됩니다. 저장 위치는 Mac이든 원하는 드라이브든 상관없습니다. 오늘도, 20년 뒤에도 Imago 없이 열 수 있습니다.

작동 방식
• Mac에 표시되는 코드를 한 번 스캔해 페어링합니다.
• iPhone을 충전해 두면 새 사진을 대개 밤사이 백업합니다. 지금 백업하려면 앱을 열기만 하면 됩니다.
• 중단된 백업은 멈춘 곳에서 이어집니다.
• iCloud 사진에 있는 원본도 내려받아 백업합니다.
• iPhone에서 삭제한 사진은 직접 결정할 때까지 백업에 남습니다.
• Mac에서 어떤 사진이든 iPhone으로 되돌릴 수 있습니다. 날짜, 위치, 앨범도 그대로입니다.

가격
7일간 모든 기능을 무료로 사용해 보세요. 그 후에는 한 번만 구입하면 새 사진과 비디오를 계속 백업합니다. 나의 모든 iPhone과 iPad에서 쓰는 Imago, 또는 가족 공유로 최대 6명까지 쓰는 Imago 패밀리. 구독이 아닙니다. 사진 복원은 언제나 무료이며, 백업은 일반 파일이라 앱이 있든 없든 그대로 남습니다.""",
mac_name="Imago: iPhone 사진 백업",
mac_sub="내 사진을 내 드라이브에",
mac_promo="iPhone 사진을 집 Wi-Fi로 내 Mac에 백업하고, iPhone 공간을 안전하게 확보하세요. 클라우드도 구독도 없습니다. Mac 앱은 무료입니다.",
mac_kw="사진 백업,iPhone,전송,저장 공간,공간 확보,중복,iCloud,대안,Wi-Fi,비디오,로컬,정리",
mac_desc="""Imago는 iPhone의 사진과 비디오를 Mac에 자동으로 백업합니다. 대개 밤사이, 집의 Wi-Fi로. 클라우드도, 계정도, 구독도 없습니다. Mac 앱은 무료입니다.

iPhone 또는 iPad의 Imago 앱과 함께 사용하세요.

사진은 집 밖으로 나가지 않습니다
사진은 iPhone에서 Mac으로 바로 전송되며, 페어링할 때 만들어진 키로 암호화됩니다. 서버를 거치지 않습니다. Imago에는 서버가 없으니까요.

안전하게 iPhone 공간 확보
각 iPhone의 보관함을 사진 앱처럼 Mac에서 봅니다. 완전히 같은 중복 사진, 비슷한 사진과 연속 촬영, 큰 비디오, 스크린샷을 찾아 줍니다. 지울 항목을 고르면, iPhone은 Mac에 검증된 사본이 있는 것만, 그리고 iPhone에서 확인한 뒤에만 삭제합니다.

드라이브에는 일반 파일로
모든 원본, Live Photo, 편집본이 Mac, 외장 드라이브 또는 네트워크 드라이브의 날짜별 폴더에 저장됩니다. Finder나 어떤 앱에서든 Imago 없이 열 수 있습니다. 오늘도, 20년 뒤에도.

Mac에서
• 모든 iPhone의 보관함, 장소, 오늘의 추억, 큰 파일
• 드라이브의 실제 폴더인 폴더
• 사진과 비디오 뷰어 겸 편집기
• 여러 대의 iPhone, 각각 자기 폴더에
• iPhone에서 삭제한 사진도 직접 결정할 때까지 백업에 보관
• 사진을 iPhone으로 되돌리기. 날짜, 위치, 앨범 그대로
• 메뉴 막대에 상주

가격
Mac 앱은 무료입니다. iPhone과 iPad에서는 7일간 모든 기능을 무료로 사용해 보고, 그 후 한 번만 구입하면 새 사진을 계속 백업합니다. 구독이 아닙니다. 사진 복원은 언제나 무료이며, 백업은 일반 파일이라 앱이 있든 없든 그대로 남습니다.""",
)

# ---------------------------------------------------------------- Portuguese (Brazil)
L["pt-BR"] = dict(
ios_name="Imago: Backup no seu Mac",
ios_sub="Libere espaço sem o iCloud",
ios_promo="Armazenamento do iPhone cheio? Faça backup de todas as fotos e vídeos no seu próprio Mac pelo Wi-Fi e libere espaço com segurança. Sem nuvem e sem assinatura.",
ios_kw="foto,backup,armazenamento,cheio,liberar espaço,transferir,icloud,alternativa,wifi,vídeo,local,mac",
ios_desc="""Armazenamento do iPhone cheio? O Imago faz backup de todas as fotos e vídeos do seu iPhone no seu próprio Mac, automaticamente, em geral à noite enquanto ele carrega, pelo seu próprio Wi-Fi. Sem nuvem, sem conta e sem assinatura.

Requer o app gratuito Imago em um Mac.

SUAS FOTOS FICAM EM CASA
As fotos vão direto do iPhone para o Mac, criptografadas com uma chave criada quando você os emparelha. Elas nunca passam por um servidor: o Imago não tem nenhum.

LIBERE O IPHONE COM SEGURANÇA
Nada é removido do iPhone até o Mac ter uma cópia verificada. No Mac, o Imago encontra duplicatas exatas, fotos parecidas, sequências, vídeos grandes e capturas de tela, e você aprova cada exclusão no iPhone. As fotos apagadas vão para Apagados, como sempre.

ARQUIVOS COMUNS NO SEU DISCO
Originais, Live Photos e edições são salvos como arquivos comuns em pastas por data, no Mac ou no disco que você escolher. Abra-os sem o Imago, hoje ou daqui a vinte anos.

COMO FUNCIONA
• Emparelhe uma vez escaneando o código no Mac.
• Deixe o iPhone carregando e o Imago faz backup das fotos novas, em geral à noite. Ou abra o app para fazer backup agora.
• Um backup interrompido continua de onde parou.
• Os originais guardados nas Fotos do iCloud também são baixados e copiados.
• As fotos que você apaga no iPhone continuam no backup até você decidir.
• Devolva qualquer foto ao iPhone a partir do Mac, com data, local e álbuns.

PREÇO
Teste todos os recursos grátis por 7 dias. Depois, uma compra única continua fazendo backup de novas fotos e vídeos: Imago, para você em todos os seus iPhones e iPads, ou Imago Família, para até 6 pessoas com o Compartilhamento Familiar. Sem assinatura. Restaurar fotos é sempre grátis, e seus backups são arquivos comuns que ficam com você, com ou sem o app.""",
mac_name="Imago: Backup de fotos iPhone",
mac_sub="Suas fotos no seu disco",
mac_promo="Faça backup das fotos do iPhone no seu próprio Mac pelo Wi-Fi e libere espaço no iPhone com segurança. Sem nuvem e sem assinatura. O app para Mac é grátis.",
mac_kw="backup de fotos,iphone,transferir,armazenamento,liberar espaço,duplicatas,icloud,wifi,vídeo",
mac_desc="""O Imago faz backup das fotos e vídeos do seu iPhone no seu Mac, automaticamente, em geral à noite, pelo seu próprio Wi-Fi. Sem nuvem, sem conta e sem assinatura. O app para Mac é grátis.

Use com o app Imago no iPhone ou iPad.

SUAS FOTOS FICAM EM CASA
As fotos vão direto do iPhone para o Mac, criptografadas com uma chave criada quando você os emparelha. Elas nunca passam por um servidor: o Imago não tem nenhum.

LIBERE O IPHONE COM SEGURANÇA
Veja a fototeca de cada iPhone no Mac, organizada como no app Fotos. O Imago encontra duplicatas exatas, fotos parecidas e sequências, vídeos grandes e capturas de tela. Você escolhe o que remover: o iPhone só apaga aquilo de que o Mac tem uma cópia verificada, e só depois que você confirma no telefone.

ARQUIVOS COMUNS NO SEU DISCO
Cada original, Live Photo e edição vai para pastas por data, no Mac, num disco externo ou de rede. Abra-os no Finder ou em qualquer app, sem o Imago, hoje ou daqui a vinte anos.

NO MAC
• Fototeca, Locais, Neste Dia e Arquivos Grandes de todos os seus iPhones
• Pastas que são pastas de verdade no disco
• Um visualizador e editor de fotos e vídeos
• Vários iPhones, cada um na sua pasta
• Fotos apagadas num iPhone continuam no backup até você decidir
• Devolva fotos ao iPhone, com data, local e álbuns
• Fica na barra de menus

PREÇO
O app para Mac é grátis. No iPhone e no iPad, teste todos os recursos grátis por 7 dias; depois, uma compra única continua fazendo backup das fotos novas. Sem assinatura. Restaurar fotos é sempre grátis, e seus backups são arquivos comuns que ficam com você, com ou sem o app.""",
)

# ---------------------------------------------------------------- Simplified Chinese
L["zh-Hans"] = dict(
ios_name="Imago：照片备份到 Mac",
ios_sub="不用 iCloud，也能腾出空间",
ios_promo="iPhone 储存空间已满？通过自家 Wi-Fi，把所有照片和视频备份到你自己的 Mac，再安全地腾出空间。不用云端，不是订阅。",
ios_kw="照片,备份,储存空间,空间不足,内存满了,清理,传输,iCloud,替代,Wi-Fi,视频,本地,Mac",
ios_desc="""iPhone 储存空间已满？Imago 通过你自家的 Wi-Fi，把 iPhone 上的所有照片和视频自动备份到你自己的 Mac，通常在夜里充电时进行。不用云端，不用账户，不是订阅。

需要在 Mac 上安装免费的 Imago app。

照片留在家里
照片从 iPhone 直接传到 Mac，用配对时生成的密钥加密。它们从不经过服务器：Imago 根本没有服务器。

安全地为 iPhone 腾出空间
在 Mac 拿到经过校验的副本之前，iPhone 上什么都不会删。Imago 在 Mac 上找出完全相同的重复项、相似照片、连拍、大视频和截屏，每一次删除都由你在 iPhone 上确认。删除的照片和往常一样进入“最近删除”。

硬盘上是普通文件
原片、实况照片和编辑后的版本，都以普通文件存进按日期整理的文件夹，放在 Mac 或你选的任何硬盘上。不用 Imago 也能打开，今天如此，二十年后也一样。

怎么用
• 扫一次 Mac 上的二维码完成配对。
• iPhone 充着电，Imago 通常在夜里备份新照片。想马上备份，打开 app 即可。
• 备份中断了，会从停下的地方接着来。
• 存在 iCloud 照片里的原片，也会下载并备份。
• 你在 iPhone 上删掉的照片，会留在备份里，直到你决定。
• 从 Mac 把任何照片放回 iPhone，日期、地点和相簿都在。

价格
免费试用全部功能 7 天。之后一次性购买，即可继续备份新的照片和视频：Imago，供你在所有 iPhone 和 iPad 上使用；或 Imago 家庭版，通过家人共享最多 6 人使用。不是订阅。恢复照片永远免费；备份是普通文件，有没有 app 都归你所有。""",
mac_name="Imago：iPhone 照片备份",
mac_sub="照片，存在你自己的硬盘上",
mac_promo="通过自家 Wi-Fi 把 iPhone 照片备份到你自己的 Mac，再安全地为 iPhone 腾出空间。不用云端，不是订阅。Mac 版免费。",
mac_kw="照片备份,iPhone,传输,储存空间,清理空间,重复照片,iCloud,替代,Wi-Fi,视频,本地,整理",
mac_desc="""Imago 通过你自家的 Wi-Fi，把 iPhone 上的照片和视频自动备份到 Mac，通常在夜里进行。不用云端，不用账户，不是订阅。Mac 版免费。

配合 iPhone 或 iPad 上的 Imago app 使用。

照片留在家里
照片从 iPhone 直接传到 Mac，用配对时生成的密钥加密。它们从不经过服务器：Imago 根本没有服务器。

安全地为 iPhone 腾出空间
在 Mac 上查看每台 iPhone 的图库，排列方式和“照片”app 一样。Imago 找出完全相同的重复项、相似照片和连拍、大视频和截屏。你选好要删的，iPhone 只删除 Mac 已有校验副本的项目，而且要你在 iPhone 上确认之后。

硬盘上是普通文件
每张原片、实况照片和编辑版本，都存进按日期整理的文件夹，放在 Mac、外置硬盘或网络硬盘上。用“访达”或任何 app 都能打开，不需要 Imago，今天如此，二十年后也一样。

在 Mac 上
• 所有 iPhone 的图库、地点、历史上的今天和大文件
• 文件夹就是硬盘上真正的文件夹
• 照片和视频的查看与编辑
• 多台 iPhone，各有各的文件夹
• 在 iPhone 上删除的照片，留在备份里直到你决定
• 把照片放回 iPhone，日期、地点和相簿都在
• 常驻菜单栏

价格
Mac 版免费。在 iPhone 和 iPad 上可免费试用全部功能 7 天，之后一次性购买即可继续备份新照片。不是订阅。恢复照片永远免费；备份是普通文件，有没有 app 都归你所有。""",
)

# ---------------------------------------------------------------- Traditional Chinese
L["zh-Hant"] = dict(
ios_name="Imago：照片備份到 Mac",
ios_sub="不用 iCloud，也能騰出空間",
ios_promo="iPhone 儲存空間已滿？透過自家 Wi-Fi，把所有照片和影片備份到你自己的 Mac，再安全地騰出空間。不用雲端，不是訂閱。",
ios_kw="照片,備份,儲存空間,空間不足,容量滿了,清理,傳輸,iCloud,替代,Wi-Fi,影片,本機,Mac",
ios_desc="""iPhone 儲存空間已滿？Imago 透過你自家的 Wi-Fi，把 iPhone 上的所有照片和影片自動備份到你自己的 Mac，通常在夜裡充電時進行。不用雲端，不用帳號，不是訂閱。

需要在 Mac 上安裝免費的 Imago app。

照片留在家裡
照片從 iPhone 直接傳到 Mac，用配對時產生的密鑰加密。它們從不經過伺服器：Imago 根本沒有伺服器。

安全地為 iPhone 騰出空間
在 Mac 取得經過驗證的副本之前，iPhone 上什麼都不會刪。Imago 在 Mac 上找出完全相同的重複項目、相似照片、連拍、大型影片和截圖，每一次刪除都由你在 iPhone 上確認。刪除的照片和往常一樣進入「最近刪除」。

硬碟上是一般檔案
原始照片、原況照片和編輯後的版本，都以一般檔案存進按日期整理的資料夾，放在 Mac 或你選的任何硬碟上。不用 Imago 也能打開，今天如此，二十年後也一樣。

怎麼用
• 掃一次 Mac 上的 QR 碼完成配對。
• iPhone 充著電，Imago 通常在夜裡備份新照片。想馬上備份，打開 app 即可。
• 備份中斷了，會從停下的地方接著來。
• 存在 iCloud 照片裡的原始檔，也會下載並備份。
• 你在 iPhone 上刪掉的照片，會留在備份裡，直到你決定。
• 從 Mac 把任何照片放回 iPhone，日期、地點和相簿都在。

價格
免費試用全部功能 7 天。之後一次性購買，即可繼續備份新的照片和影片：Imago，供你在所有 iPhone 和 iPad 上使用；或 Imago 家庭版，透過家人共享最多 6 人使用。不是訂閱。回復照片永遠免費；備份是一般檔案，有沒有 app 都歸你所有。""",
mac_name="Imago：iPhone 照片備份",
mac_sub="照片，存在你自己的硬碟上",
mac_promo="透過自家 Wi-Fi 把 iPhone 照片備份到你自己的 Mac，再安全地為 iPhone 騰出空間。不用雲端，不是訂閱。Mac 版免費。",
mac_kw="照片備份,iPhone,傳輸,儲存空間,清理空間,重複照片,iCloud,替代,Wi-Fi,影片,本機,整理",
mac_desc="""Imago 透過你自家的 Wi-Fi，把 iPhone 上的照片和影片自動備份到 Mac，通常在夜裡進行。不用雲端，不用帳號，不是訂閱。Mac 版免費。

搭配 iPhone 或 iPad 上的 Imago app 使用。

照片留在家裡
照片從 iPhone 直接傳到 Mac，用配對時產生的密鑰加密。它們從不經過伺服器：Imago 根本沒有伺服器。

安全地為 iPhone 騰出空間
在 Mac 上查看每台 iPhone 的圖庫，排列方式和「照片」app 一樣。Imago 找出完全相同的重複項目、相似照片和連拍、大型影片和截圖。你選好要刪的，iPhone 只刪除 Mac 已有驗證副本的項目，而且要你在 iPhone 上確認之後。

硬碟上是一般檔案
每張原始照片、原況照片和編輯版本，都存進按日期整理的資料夾，放在 Mac、外接硬碟或網路硬碟上。用 Finder 或任何 app 都能打開，不需要 Imago，今天如此，二十年後也一樣。

在 Mac 上
• 所有 iPhone 的圖庫、地點、歷史上的今天和大型檔案
• 資料夾就是硬碟上真正的資料夾
• 照片和影片的檢視與編輯
• 多台 iPhone，各有各的資料夾
• 在 iPhone 上刪除的照片，留在備份裡直到你決定
• 把照片放回 iPhone，日期、地點和相簿都在
• 常駐選單列

價格
Mac 版免費。在 iPhone 和 iPad 上可免費試用全部功能 7 天，之後一次性購買即可繼續備份新照片。不是訂閱。回復照片永遠免費；備份是一般檔案，有沒有 app 都歸你所有。""",
)

LIMITS = dict(name=30, sub=30, promo=170, kw=100, desc=4000)
bad = []
for loc, d in L.items():
    for app in ("ios", "mac"):
        for f, lim in LIMITS.items():
            v = d[f"{app}_{f}"]
            if len(v) > lim:
                bad.append(f"{loc} {app}_{f}: {len(v)} > {lim}")
        if app == "ios" and loc == "en-US":
            assert "Requires the free Imago app on a Mac" in d["ios_desc"]
if bad:
    print("\n".join(bad)); raise SystemExit(1)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "listing.json")
json.dump(dict(support=SUPPORT, marketing=MARKETING, locales=L), open(out, "w"), ensure_ascii=False, indent=1)
print("ok", len(L), "locales ->", out)
