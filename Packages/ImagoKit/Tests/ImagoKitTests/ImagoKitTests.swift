import Foundation
import Testing
@testable import ImagoKit

private let key = ResourceKey(assetID: "ABC-123/L0/001", kind: .photo, revision: "original")

private func metadata(filename: String = "IMG_4821.HEIC", date: Date? = Date(timeIntervalSince1970: 1_792_506_612)) -> AssetMetadata {
    AssetMetadata(
        assetID: key.assetID, originalFilename: filename, creationDate: date, modificationDate: date,
        mediaType: "photo", pixelWidth: 4032, pixelHeight: 3024, duration: 0, isFavorite: true,
        location: .init(latitude: 37.33, longitude: -122.0, altitude: 10), albums: ["Trips"]
    )
}

@Suite struct FrameCodecTests {
    @Test func controlMessageRoundTrips() throws {
        let entry = ManifestEntry(
            metadata: metadata(),
            resources: [ResourceDescriptor(key: key, originalFilename: "IMG_4821.HEIC", uti: "public.heic")]
        )
        let frames: [Frame] = [
            .control(.hello(deviceID: "d1", deviceName: "iPhone", protocolVersion: 4, proof: Data([1, 2]))),
            .control(.manifest([entry])),
            .control(.need([ResumePoint(key: key, offset: 42)])),
            .control(.endResource(key, sha256: "abc")),
            .control(.goodbye),
        ]
        var decoder = FrameDecoder()
        for frame in frames { decoder.append(try FrameCodec.encode(frame)) }
        for frame in frames { #expect(try decoder.next() == frame) }
        #expect(try decoder.next() == nil)
    }

    @Test func chunkRoundTripsAcrossSplitReads() throws {
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        let encoded = try FrameCodec.encode(.chunk(key: key, offset: 1_000_000, data: payload))

        var decoder = FrameDecoder()
        var decoded: Frame?
        // Feed the bytes in awkward pieces, like TCP would.
        var index = 0
        while index < encoded.count {
            let end = min(index + 7_777, encoded.count)
            decoder.append(encoded.subdata(in: index..<end))
            if let frame = try decoder.next() { decoded = frame }
            index = end
        }
        #expect(decoded == .chunk(key: key, offset: 1_000_000, data: payload))
    }

    @Test func rejectsOversizedFrames() {
        var decoder = FrameDecoder()
        var header = Data()
        header.appendBigEndian(UInt32(FrameCodec.maxFrameSize + 1))
        decoder.append(header)
        #expect(throws: FrameError.frameTooLarge(FrameCodec.maxFrameSize + 1)) { try decoder.next() }
    }
}

@Suite struct LibraryLayoutTests {
    let layout = LibraryLayout(timeZone: TimeZone(identifier: "UTC")!)

    @Test func originalsKeepTheirNamesUnderDatedFolders() {
        let photo = ResourceDescriptor(key: key, originalFilename: "IMG_4821.HEIC", uti: "public.heic")
        #expect(layout.relativePath(for: photo, of: metadata()) == "2026/10/2026-10-20_143012_IMG_4821.HEIC")

        var motion = photo
        motion.key.kind = .pairedVideo
        motion.originalFilename = "IMG_4821.MOV"
        #expect(layout.relativePath(for: motion, of: metadata()) == "2026/10/2026-10-20_143012_IMG_4821.MOV")
    }

    @Test func editsAreNamedAfterThePrimaryFile() {
        let edit = ResourceDescriptor(
            key: ResourceKey(assetID: key.assetID, kind: .fullSizePhoto, revision: "1"),
            originalFilename: "FullSizeRender.jpg", uti: "public.jpeg"
        )
        #expect(layout.relativePath(for: edit, of: metadata()) == "2026/10/2026-10-20_143012_IMG_4821_edited.jpg")
        #expect(layout.sidecarPath(for: metadata()) == "2026/10/2026-10-20_143012_IMG_4821.json")
    }

    @Test func sidecarsOfDifferentAssetsGetNumberedNames() {
        let base = "2026/10/2026-10-20_143012_IMG_4821.json"
        #expect(layout.sidecarPath(for: metadata()) { _ in true } == base)
        #expect(layout.sidecarPath(for: metadata()) { $0 != base } == "2026/10/2026-10-20_143012_IMG_4821 (2).json")
        let taken: Set = [base, "2026/10/2026-10-20_143012_IMG_4821 (2).json"]
        #expect(layout.sidecarPath(for: metadata()) { !taken.contains($0) } == "2026/10/2026-10-20_143012_IMG_4821 (3).json")
    }

    @Test func numberedNames() {
        #expect(LibraryLayout.numbered("2026/10/IMG_1.HEIC", 2) == "2026/10/IMG_1 (2).HEIC")
        #expect(LibraryLayout.numbered("Undated/README", 3) == "Undated/README (3)")
        #expect(LibraryLayout.numbered("a.b/c", 2) == "a.b/c (2)")
    }

    @Test func undatedAndUnsafeNames() {
        let photo = ResourceDescriptor(key: key, originalFilename: "a/b:c.jpg", uti: "public.jpeg")
        #expect(layout.relativePath(for: photo, of: metadata(date: nil)) == "Undated/a_b_c.jpg")
    }
}

@Suite struct PairingTests {
    @Test func qrStringRoundTrips() throws {
        let info = PairingInfo.generate(serverName: "Studio Mac")
        #expect(info.secret.count == 32)
        #expect(PairingInfo(qrString: info.qrString) == info)
        #expect(PairingInfo(qrString: "https://example.com") == nil)
    }
}

@Suite struct HelloProofTests {
    let key = Secret.random()
    let binding = Data(repeating: 9, count: 32)

    @Test func acceptsOnlyTheSameKeyDeviceAndSession() {
        let proof = HelloProof.make(key: key, deviceID: "phone-a", binding: binding)
        #expect(HelloProof.isValid(proof, key: key, deviceID: "phone-a", binding: binding))
        #expect(!HelloProof.isValid(proof, key: Secret.random(), deviceID: "phone-a", binding: binding))
        #expect(!HelloProof.isValid(proof, key: key, deviceID: "phone-b", binding: binding))
        #expect(!HelloProof.isValid(proof, key: key, deviceID: "phone-a", binding: Data(repeating: 8, count: 32)))
    }
}

@Suite struct HashingTests {
    @Test func fileAndDataHashesMatch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let data = Data(repeating: 7, count: 3 << 20)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FileHasher.sha256(of: url) == FileHasher.sha256(of: data))
        #expect(FileHasher.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct LibraryRecordTests {
    @Test func phonesKeepTheirFoldersAndNewOnesGetFreeNames() {
        var record = LibraryRecord()
        #expect(record.folder(for: "A", name: "iPhone", preferred: "iPhone") == "iPhone")
        #expect(record.folder(for: "B", name: "iPhone", preferred: "iPhone") == "iPhone 2")
        #expect(record.folder(for: "C", name: "iphone", preferred: "IPHONE") == "IPHONE 3")
        // Pairing again, under a new name, keeps the folder and updates the name.
        #expect(record.folder(for: "A", name: "Tennis iPhone", preferred: "Tennis iPhone") == "iPhone")
        #expect(record.device("A")?.name == "Tennis iPhone")
        #expect(record.devices.count == 3)
    }

    @Test func savesAndLoadsFromTheLibraryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try LibraryRecord.load(from: root) == nil)

        var record = LibraryRecord(createdAt: Date(timeIntervalSince1970: 1_792_506_612))
        record.folder(for: "A", name: "Jia's iPhone", preferred: "Jia's iPhone")
        try record.save(to: root)
        #expect(try LibraryRecord.load(from: root) == record)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".photobackup/library.json").path))
    }

    @Test func sidecarsWithoutADeviceStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let old = Sidecar(metadata: metadata(), files: [])
        let decoded = try decoder.decode(Sidecar.self, from: encoder.encode(old))
        #expect(decoded.deviceID == nil)
        #expect(!String(decoding: try encoder.encode(old), as: UTF8.self).contains("deviceID"))

        let new = Sidecar(metadata: metadata(), files: [], deviceID: "A")
        #expect(try decoder.decode(Sidecar.self, from: encoder.encode(new)).deviceID == "A")
    }
}
