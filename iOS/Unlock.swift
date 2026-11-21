import StoreKit
import SwiftUI

/// What this Apple Account may do: a free 7-day trial, then a one-time unlock. The Mac app is free;
/// only backing up new photos from iPhone and iPad needs the unlock. Restoring, the Mac's changes and
/// everything already on the Mac never do.
///
/// The trial is built in: it starts with the first backup, and its start date is kept in iCloud
/// Keychain, so it survives a reinstall and carries to the person's other iPhones and iPads.
///
/// App Store products, all non-consumable:
/// - `trial`: a free "7-Day Trial", App Review's suggested form of a trial. Not offered (Xcode's test
///   store refuses to sell it, error 2010), but if App Review asks for it, owning it starts the trial too.
/// - `single`: $14.99, for one Apple ID. Family Sharing off.
/// - `family`: $39.99, for up to six people. Family Sharing on.
/// - `upgrade`: $24.99, from `single` to family, offered only to owners of `single`. Family Sharing on.
///
/// In App Store Connect, Family Sharing can be turned on for a product but never off again.
@MainActor @Observable
final class Unlock {
    static let shared = Unlock()

    enum ProductID {
        static let trial = "com.ljworkshop.imago.trial"
        static let single = "com.ljworkshop.imago.unlock"
        static let family = "com.ljworkshop.imago.family"
        static let upgrade = "com.ljworkshop.imago.familyupgrade"
        static let all = [trial, single, family, upgrade]
    }

    static let trialDays = 7

    enum Access: Equatable {
        /// Not read from StoreKit yet.
        case unknown
        /// The trial hasn't started: it starts with the first backup.
        case new
        case trial(ends: Date)
        case trialEnded
        case unlocked(family: Bool)
    }

    private(set) var access: Access = .unknown
    /// The products as the App Store has them, with prices in the user's currency. Empty until loaded.
    private(set) var products: [String: Product] = [:]
    private(set) var loadingProducts = false
    /// The product being bought, while Apple's sheet is up.
    private(set) var buying: String?
    private(set) var restoring = false
    /// What went wrong buying or restoring, or that a purchase waits for a parent's approval.
    var message: String?
    /// The unlock sheet is showing.
    var offering = false
    /// Just bought the $14.99 unlock: the sheet stays to say thank you and offer the family upgrade.
    private(set) var justBoughtSingle = false
    /// A backup the user asked for, waiting on the unlock: runs as soon as Imago is unlocked or the trial starts.
    var pendingBackup: (() -> Void)?

    /// The last day the unlock was shown on its own, so the reminder comes at most once a day.
    private var lastReminder: Date? {
        get { UserDefaults.standard.object(forKey: "unlockReminder") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "unlockReminder") }
    }

    private var updates: Task<Void, Never>?

    /// When the trial started, in iCloud Keychain: kept through a reinstall, shared with the person's other devices.
    private var trialStart: Date? {
        get { UnlockKeychain.read("trialStart").flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)) }
        set { UnlockKeychain.write("trialStart", newValue.map { String($0.timeIntervalSince1970) }, synchronized: true) }
    }

    /// Products this device has seen bought, so a confirmed purchase counts even if StoreKit's list of what's
    /// owned lags behind (as Xcode's test store does). A refund takes it out again.
    private var remembered: Set<String> {
        get { Set((UnlockKeychain.read("purchases") ?? "").split(separator: ",").map(String.init)) }
        set { UnlockKeychain.write("purchases", newValue.isEmpty ? nil : newValue.sorted().joined(separator: ","), synchronized: false) }
    }

    private init() {
        // Purchases made elsewhere (another device, Ask to Buy approved later, a refund) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    if transaction.revocationDate == nil { self?.remembered.insert(transaction.productID) }
                }
                await self?.refresh()
            }
        }
    }

    /// Whether a backup may start now. Reads StoreKit first if it hasn't been read. The first backup starts the trial.
    func allowsBackup() async -> Bool {
        if access == .unknown { await refresh() }
        if access == .new { startTrial() }
        switch access {
        case .unlocked: return true
        case .trial(let ends):
            if ends > .now { return true }
            access = .trialEnded
            return false
        case .new, .trialEnded, .unknown: return false
        }
    }

    /// Owns the $14.99 unlock and not a family one, so the family upgrade is what's on offer.
    var canUpgrade: Bool { access == .unlocked(family: false) }

    /// Whole days left in the trial, counting a part day as one, so the last day says "1 day".
    var trialDaysLeft: Int? {
        guard case .trial(let ends) = access else { return nil }
        return max(1, Int((ends.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    /// Starts the 7 days now, unless they've started already (here, or on another device or install).
    func startTrial() {
        guard trialStart == nil else { return }
        trialStart = .now
        log.notice("Unlock: the free trial started")
        settle(owned: remembered, storeTrialStart: nil)
    }

    /// Reads what this Apple Account owns, including purchases shared by family: StoreKit's current list,
    /// its full history and the purchases remembered here. Works offline: StoreKit keeps it on the device.
    func refresh() async {
        var owned = remembered
        var revoked: Set<String> = []
        var storeTrialStart: Date?
        func take(_ result: VerificationResult<StoreKit.Transaction>) {
            switch result {
            case .verified(let transaction) where transaction.revocationDate == nil:
                owned.insert(transaction.productID)
                if transaction.productID == ProductID.trial { storeTrialStart = transaction.originalPurchaseDate }
            case .verified(let transaction):
                revoked.insert(transaction.productID)
            case .unverified(let transaction, let error):
                log.error("Unlock: couldn't verify \(transaction.productID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for await result in Transaction.currentEntitlements { take(result) }
        for await result in Transaction.all { take(result) }
        if !revoked.isEmpty {
            log.notice("Unlock: refunded \(revoked.sorted(), privacy: .public)")
            owned.subtract(revoked)
        }
        if owned != remembered { remembered = owned }
        settle(owned: owned, storeTrialStart: storeTrialStart)
    }

    private func settle(owned: Set<String>, storeTrialStart: Date?) {
        let trialStart = [self.trialStart, storeTrialStart].compactMap { $0 }.min()
        if owned.contains(ProductID.family) || owned.contains(ProductID.upgrade) {
            access = .unlocked(family: true)
        } else if owned.contains(ProductID.single) {
            access = .unlocked(family: false)
        } else if let trialStart {
            let ends = trialStart.addingTimeInterval(TimeInterval(Self.trialDays) * 86_400)
            access = ends > .now ? .trial(ends: ends) : .trialEnded
        } else {
            access = .new
        }
        log.notice("Unlock: owns \(owned.sorted(), privacy: .public); \(String(describing: self.access), privacy: .public)")
        startPendingBackup()
    }

    private func startPendingBackup() {
        guard let backup = pendingBackup else { return }
        switch access {
        case .unlocked: break
        case .trial(let ends) where ends > .now: break
        default: return
        }
        pendingBackup = nil
        backup()
    }

    /// When the app opens: shows the unlock at most once a day until Imago is bought, so the trial and
    /// the price are never a surprise. Not while a backup runs or another sheet is up.
    func remindIfDue() async {
        await refresh()
        switch access {
        case .trial, .trialEnded: break
        case .unknown, .new, .unlocked: return
        }
        if let last = lastReminder, Calendar.current.isDateInToday(last) { return }
        guard !offering else { return }
        lastReminder = .now
        offering = true
    }

    func loadProducts() async {
        guard products.isEmpty, !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let found = try await Product.products(for: ProductID.all)
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        } catch {
            log.error("Couldn't load products: \(String(describing: error), privacy: .public)")
        }
    }

    func buy(_ id: String) async {
        guard let product = products[id], buying == nil else { return }
        buying = id
        defer { buying = nil }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = String(localized: "The App Store couldn't confirm this purchase. Please try again.")
                    return
                }
                await transaction.finish()
                log.notice("Unlock: bought \(transaction.productID, privacy: .public)")
                remembered.insert(transaction.productID)
                await refresh()
                if transaction.productID == ProductID.single {
                    // Stay open: say thank you, and that it can cover the family too.
                    justBoughtSingle = true
                } else if await allowsBackup() {
                    offering = false
                }
            case .pending:
                message = String(localized: "Waiting for approval. Imago unlocks as soon as it's approved.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// The sheet closed: a backup waiting on it is dropped, and the thank-you is said.
    func sheetClosed() {
        pendingBackup = nil
        justBoughtSingle = false
    }

    /// Asks the App Store for this Apple ID's purchases again, e.g. after signing in on a new device.
    func restore() async {
        restoring = true
        defer { restoring = false }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if case .unlocked = access {
                offering = false
            } else {
                message = String(localized: "No purchase was found for this Apple Account.")
            }
        } catch StoreKitError.userCancelled {
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Views

/// On the home screen while paired and not unlocked: days left in the trial, or that backups are paused.
struct UnlockCard: View {
    @Environment(Unlock.self) private var unlock

    var body: some View {
        if let text = content {
            HStack(spacing: 14) {
                Image(systemName: text.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(text.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title).font(.body.weight(.medium))
                    Text(text.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(text.button) {
                    // Not started yet: Start begins the 7 days here, with no purchase.
                    if unlock.access == .new { unlock.startTrial() } else { unlock.offering = true }
                }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
            .card()
        }
    }

    private var content: (symbol: String, tint: Color, title: String, note: String, button: String)? {
        switch unlock.access {
        case .new:
            return ("gift.fill", .pink, String(localized: "Try Imago free for 7 days"),
                    String(localized: "Every feature, then a one-time unlock."), String(localized: "Start"))
        case .trial:
            let days = unlock.trialDaysLeft ?? 1
            let title = days == 1 ? String(localized: "Free trial: 1 day left") : String(localized: "Free trial: \(days) days left")
            return ("hourglass", .pink, title,
                    String(localized: "Then a one-time unlock keeps backups going."), String(localized: "Unlock"))
        case .trialEnded:
            return ("pause.circle.fill", .orange, String(localized: "Backups are paused"),
                    String(localized: "Your free trial has ended. Photos already on your Mac stay there."), String(localized: "Unlock"))
        case .unlocked(family: false):
            return ("person.3.fill", .green, String(localized: "Imago is unlocked for you"),
                    String(localized: "Upgrade to Imago Family to cover up to 6 people in your Family Sharing group."), String(localized: "Upgrade"))
        case .unknown, .unlocked(family: true):
            return nil
        }
    }
}

/// The trial, the two unlocks and the family upgrade, with Apple's prices.
struct UnlockSheet: View {
    @Environment(Unlock.self) private var unlock
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if unlock.products.isEmpty {
                        if unlock.loadingProducts {
                            ProgressView().padding(.vertical, 30)
                        } else {
                            VStack(spacing: 12) {
                                Text("Can't reach the App Store right now.")
                                    .foregroundStyle(.secondary)
                                Button("Try Again") { Task { await unlock.loadProducts() } }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 20)
                        }
                    } else {
                        options
                    }
                    notNow
                    if let message = unlock.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 10) {
                        Button(unlock.restoring ? String(localized: "Restoring…") : String(localized: "Restore Purchases")) {
                            Task { await unlock.restore() }
                        }
                        .disabled(unlock.restoring || unlock.buying != nil)
                        Text("One-time purchase. No subscription. Restoring photos is always free, and photos already on your Mac stay yours, unlocked or not.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            unlock.message = nil
            await unlock.refresh()
            await unlock.loadProducts()
        }
        .onDisappear { unlock.sheetClosed() }
    }

    /// Under the options: carry on without buying, for now.
    @ViewBuilder private var notNow: some View {
        switch unlock.access {
        case .trial:
            Button("Continue Free Trial") { dismiss() }
                .font(.headline)
        case .unlocked:
            Button("Done") { dismiss() }
                .font(.headline)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        default:
            EmptyView()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: unlock.justBoughtSingle ? "checkmark.seal.fill" : unlock.canUpgrade ? "person.3.fill" : "lock.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var title: String {
        if unlock.justBoughtSingle { return String(localized: "Thank you!") }
        return unlock.canUpgrade ? String(localized: "Share Imago with your family") : String(localized: "Unlock Imago")
    }

    private var subtitle: String {
        if unlock.justBoughtSingle {
            return String(localized: "Imago is unlocked on all your iPhones and iPads. To cover your family too, upgrade to Imago Family anytime.")
        }
        return switch unlock.access {
        case .new:
            String(localized: "Try every feature free for 7 days. After that, a one-time unlock keeps backing up new photos and videos.")
        case .trial:
            (unlock.trialDaysLeft ?? 1) == 1
                ? String(localized: "Your free trial has 1 day left. Unlock once to keep backing up new photos and videos.")
                : String(localized: "Your free trial has \(unlock.trialDaysLeft ?? 1) days left. Unlock once to keep backing up new photos and videos.")
        case .trialEnded:
            String(localized: "Your free trial has ended, so new photos and videos aren't backed up. Unlock once to start again.")
        case .unlocked(family: false):
            String(localized: "Your purchase covers you. Upgrade to cover up to 6 people in your Family Sharing group, each on their own iPhones and iPads.")
        case .unlocked(family: true):
            String(localized: "Imago is unlocked for your family. Thank you! Everyone in your Family Sharing group just installs Imago on their own iPhone or iPad, and it's unlocked for them too.")
        case .unknown:
            ""
        }
    }

    @ViewBuilder private var options: some View {
        VStack(spacing: 12) {
            switch unlock.access {
            case .new:
                Button {
                    unlock.startTrial()
                    dismiss()
                } label: {
                    card(title: String(localized: "7-Day Free Trial"), note: String(localized: "Nothing to pay. It ends on its own."),
                         price: String(localized: "Free"), busy: false, prominent: true)
                }
                .buttonStyle(.plain)
                option(Unlock.ProductID.single, title: String(localized: "Imago"),
                       note: String(localized: "For you, on all your iPhones and iPads"))
                option(Unlock.ProductID.family, title: String(localized: "Imago Family"),
                       note: String(localized: "For up to 6 people with Family Sharing"))
            case .trial, .trialEnded, .unknown:
                option(Unlock.ProductID.single, title: String(localized: "Imago"),
                       note: String(localized: "For you, on all your iPhones and iPads"), prominent: true)
                option(Unlock.ProductID.family, title: String(localized: "Imago Family"),
                       note: String(localized: "For up to 6 people with Family Sharing"))
            case .unlocked(family: false):
                option(Unlock.ProductID.upgrade, title: String(localized: "Upgrade to Imago Family"),
                       note: String(localized: "For up to 6 people with Family Sharing"), prominent: true)
            case .unlocked(family: true):
                EmptyView()
            }
            if unlock.access != .unlocked(family: true) {
                Text("With Imago Family, everyone in your Family Sharing group just installs Imago on their own iPhone or iPad. It's unlocked for them automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func option(_ id: String, title: String, note: String, prominent: Bool = false) -> some View {
        let product = unlock.products[id]
        let price = product?.displayPrice ?? ""
        return Button {
            Task { await unlock.buy(id) }
        } label: {
            card(title: title, note: note, price: price, busy: unlock.buying == id, prominent: prominent)
        }
        .buttonStyle(.plain)
        .disabled(product == nil || unlock.buying != nil || unlock.restoring)
    }

    private func card(title: String, note: String, price: String, busy: Bool, prominent: Bool) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(note)
                        .font(.caption)
                        .opacity(0.8)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                } else {
                    Text(price).font(.headline.monospacedDigit())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// At the foot of the home screen with Imago Family.
struct UnlockFooter: View {
    @Environment(Unlock.self) private var unlock

    var body: some View {
        switch unlock.access {
        case .unlocked(family: true):
            Label("Imago Family", systemImage: "person.3.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Small strings in the keychain, which outlives the app: an uninstall leaves them. `synchronized` ones
/// go to iCloud Keychain, and so to the person's other devices.
enum UnlockKeychain {
    private static let service = "com.ljworkshop.imago.unlock"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String?, synchronized: Bool) {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(match as CFDictionary)
        guard let value else { return }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronized, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: Data(value.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("Keychain: couldn't save \(account, privacy: .public): \(status)") }
    }
}
