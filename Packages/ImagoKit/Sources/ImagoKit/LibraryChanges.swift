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

        /// The protocol version a phone needs to understand it.
        public var minimumVersion: Int {
            if case .deleteAlbum = self { return 6 }
            return 4
        }
    }

    public var id: UUID
    public var action: Action
    public var assetIDs: [String]
    /// About how much space the change frees on the phone (deletions only).
    public var bytes: UInt64?
    public var createdAt: Date

    public init(id: UUID = UUID(), action: Action, assetIDs: [String], bytes: UInt64? = nil, createdAt: Date = .now) {
        self.id = id
        self.action = action
        self.assetIDs = assetIDs
        self.bytes = bytes
        self.createdAt = createdAt
    }
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

    public init(changeID: UUID, outcome: Outcome, assetCount: Int, detail: String? = nil, date: Date = .now) {
        self.changeID = changeID
        self.outcome = outcome
        self.assetCount = assetCount
        self.detail = detail
        self.date = date
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
        }
    }
}
