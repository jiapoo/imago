import Foundation

/// A change the Mac asks the phone to make to its Photos library. Nothing happens until the user
/// reviews it on the phone; deletions also get iOS's own confirmation.
public struct LibraryChange: Codable, Sendable, Hashable, Identifiable {
    public enum Action: Codable, Sendable, Hashable {
        /// Moves the assets to Recently Deleted. The Mac only asks for assets it has fully backed up.
        case delete
        /// Adds to the album with this title, creating it if there isn't one.
        case addToAlbum(String)
        case removeFromAlbum(String)
        case setFavorite(Bool)
        /// Version 6: deletes the regular album with this title, as Photos does: its photos stay in the
        /// library. Has no assets. Sent only to phones on version 6 or later.
        case deleteAlbum(String)
        /// Version 7: puts these backed-up photos and videos back in the library: ones deleted on the
        /// phone that the user wants back. The phone asks for the files (`restoreRequest`) once the user
        /// approves; the report says the new asset IDs (`ChangeReport.restored`).
        case restore

        /// The protocol version a phone needs to understand it.
        public var minimumVersion: Int {
            switch self {
            case .deleteAlbum: 6
            case .restore: 7
            default: 4
            }
        }
    }

    public var id: UUID
    public var action: Action
    public var assetIDs: [String]
    /// About how much space the change frees on the phone (deletions only).
    public var bytes: UInt64?
    public var createdAt: Date
    /// Version 7: 2 when the Mac asks again after the user said no on the phone (nil: the first time).
    /// A change goes round once more at most: if it's turned down again, that's the answer.
    public var round: Int?
    /// For a `restore`: files from the Mac the phone never had (an edit made there, a file added in
    /// Finder), not ones deleted on it. A phone that knows this adds them right away, as it does
    /// favorites; an older one shows them as put-backs to review.
    public var isNew: Bool?

    public init(id: UUID = UUID(), action: Action, assetIDs: [String], bytes: UInt64? = nil, createdAt: Date = .now, round: Int? = nil,
                isNew: Bool? = nil) {
        self.id = id
        self.action = action
        self.assetIDs = assetIDs
        self.bytes = bytes
        self.createdAt = createdAt
        self.round = round
        self.isNew = isNew
    }

    /// Files from the Mac to add to the phone's library (see `isNew`).
    public var addsFromMac: Bool { action == .restore && isNew == true }

    /// Asked a second time, after the user said no.
    public var isAskedAgain: Bool { (round ?? 1) > 1 }
}

public struct ChangeReport: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        case applied
        /// The user said no, on the phone or in iOS's delete confirmation.
        case declined
        case failed
    }

    public var changeID: UUID
    public var outcome: Outcome
    /// Assets the change was made to; some may have been gone already.
    public var assetCount: Int
    public var detail: String?
    public var date: Date
    /// Version 7, for a `restore`: each put-back asset's old ID (the backup's) and its new one on the phone.
    public var restored: [String: String]?

    public init(changeID: UUID, outcome: Outcome, assetCount: Int, detail: String? = nil, date: Date = .now,
                restored: [String: String]? = nil) {
        self.changeID = changeID
        self.outcome = outcome
        self.assetCount = assetCount
        self.detail = detail
        self.date = date
        self.restored = restored
    }
}

extension LibraryChange {
    /// "Delete 12 items", "Add 3 items to “Trip”"…
    public var summary: String {
        let items = assetIDs.count == 1 ? "1 item" : "\(assetIDs.count.formatted()) items"
        switch action {
        case .delete: return "Delete \(items)"
        case .addToAlbum(let album): return "Add \(items) to “\(album)”"
        case .removeFromAlbum(let album): return "Remove \(items) from “\(album)”"
        case .setFavorite(let on): return on ? "Favorite \(items)" : "Unfavorite \(items)"
        case .deleteAlbum(let album): return "Delete album “\(album)”"
        case .restore: return isNew == true ? "Add \(items) from the Mac" : "Put back \(items)"
        }
    }

    /// SF Symbol for the action.
    public var symbol: String {
        switch action {
        case .delete: "trash"
        case .addToAlbum: "rectangle.stack.badge.plus"
        case .removeFromAlbum: "rectangle.stack.badge.minus"
        case .setFavorite(let on): on ? "heart.fill" : "heart.slash"
        case .deleteAlbum: "rectangle.stack.badge.minus"
        case .restore: isNew == true ? "plus.square.on.square" : "arrow.uturn.backward.circle"
        }
    }
}
