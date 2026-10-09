//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        private var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.owningApplication == .current {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.title == ControlItem.Identifier.iceIcon.rawValue else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.info == item.info }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// Context for a temporarily shown menu bar item.
    private struct TempShownItemContext {
        /// The information associated with the item.
        let info: MenuBarItemInfo

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The window of the item's shown interface.
        let shownInterfaceWindow: WindowInfo?

        /// A Boolean value that indicates whether the menu bar item's interface is showing.
        var isShowingInterface: Bool {
            guard let currentWindow = shownInterfaceWindow.flatMap({ WindowInfo(windowID: $0.windowID) }) else {
                return false
            }
            return if
                currentWindow.layer != CGWindowLevelForKey(.popUpMenuWindow),
                let owningApplication = currentWindow.owningApplication
            {
                owningApplication.isActive && currentWindow.isOnScreen
            } else {
                currentWindow.isOnScreen
            }
        }
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cached window identifiers for the most recent items.
    private var cachedItemWindowIDs = [CGWindowID]()

    /// Persisted per-section item order. Maps section keys ("visible", "hidden",
    /// "alwaysHidden") to an ordered list of stable item identifiers, from left
    /// to right in the menu bar.
    private var savedSectionOrder = [String: [String]]()

    /// Stable identifiers of items that have been seen before, used to
    /// distinguish genuinely new items from items that merely moved.
    private var knownItemIdentifiers = Set<String>()

    /// A Boolean value that indicates whether a saved section/order restore is
    /// in progress. While `true`, the saved section order is not overwritten,
    /// and the restore chain continues across its own recaches.
    private var isRestoringItemOrder = false

    /// The time at which the current restore began, used to reset the restore
    /// flag if it becomes stuck.
    private var isRestoringItemOrderStartDate: Date?

    /// Context values for the current temporarily shown items.
    private var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    private var tempShownItemsTimer: Timer?

    /// The last time a menu bar item was moved.
    private var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    private var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    private var itemMoveCount = 0

    /// A Boolean value that indicates whether a mouse button is down.
    private var isMouseButtonDown = false

    /// Event type mask for tracking mouse events.
    private let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        loadPersistedItemOrder()
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        Publishers.Merge(
            UniversalEventMonitor.publisher(for: mouseTrackingMask),
            RunLoopLocalEventMonitor.publisher(for: mouseTrackingMask, mode: .eventTracking)
        )
        .removeDuplicates()
        .sink { [weak self] event in
            guard let self else {
                return
            }
            switch event.type {
            case .mouseMoved:
                lastMouseMoveStartDate = .now
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                isMouseButtonDown = true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                isMouseButtonDown = false
            default:
                break
            }
        }
        .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    private func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) was not cached")
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    private func uncheckedCacheItems(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem]
    ) {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, MoveDestination)]()

        for item in otherItems {
            if let context = tempShownItemContexts.first(where: { $0.info == item.info }) {
                // Keep track of temporarily shown items and their return destinations separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return destinations to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnDestination))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, destination) in tempShownItems {
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(of: targetItem.info)
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let index = cache[section].firstIndex(of: targetItem.info)
                    {
                        let clampedIndex = (index - 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
        }

        itemCache = cache
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    ///
    /// - Parameter force: When `true`, the cache is updated even if the item
    ///   windows haven't changed and items have recently moved. Used to pick
    ///   up the results of internal item moves.
    func cacheItemsIfNeeded(force: Bool = false) async {
        do {
            try await waitForItemsToStopMoving(timeout: .seconds(1))
        } catch is TaskTimeoutError {
            logSkippingCache(reason: "an item is currently being moved")
            return
        } catch {
            guard force || !itemHasRecentlyMoved else {
                logSkippingCache(reason: "an item was recently moved")
                return
            }
        }

        let itemWindowIDs = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
        if !force, cachedItemWindowIDs == itemWindowIDs {
            logSkippingCache(reason: "item windows have not changed")
            return
        }
        let previousWindowIDs = cachedItemWindowIDs
        cachedItemWindowIDs = itemWindowIDs

        // Reset the restore flag if it has been stuck for too long, so that
        // stale state can't block section order saves indefinitely.
        if
            isRestoringItemOrder,
            let restoreStartDate = isRestoringItemOrderStartDate,
            Date.now.timeIntervalSince(restoreStartDate) > 10
        {
            isRestoringItemOrder = false
            isRestoringItemOrderStartDate = nil
        }

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        let hiddenControlItem = items.firstIndex(of: .hiddenControlItem).map { items.remove(at: $0) }
        let alwaysHiddenControlItem = items.firstIndex(of: .alwaysHiddenControlItem).map { items.remove(at: $0) }

        guard let hiddenControlItem else {
            Logger.itemManager.warning("Missing control item for hidden section")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
            return
        }

        do {
            if let alwaysHiddenControlItem {
                try await enforceControlItemOrder(
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
            }

            // Relocate brand-new items that macOS placed to the left of the
            // hidden control item, and keep the Ice icon in the visible section.
            if await relocateNewLeftmostItems(items, hiddenControlItem: hiddenControlItem) {
                scheduleRestoringRecache()
                return
            }

            // Begin a restore chain when apps have restarted and macOS placed
            // their items somewhere else. The chain continues across the
            // recaches triggered by its own moves.
            if
                !isRestoringItemOrder,
                windowIDsDisappeared(items, previousWindowIDs: previousWindowIDs),
                !ownMovesOccurred(within: MenuBarItemManager.restoreCooldown)
            {
                isRestoringItemOrder = true
                isRestoringItemOrderStartDate = .now
            }

            if isRestoringItemOrder {
                var didRestore = await restoreItemsToSavedSections(
                    items,
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
                if !didRestore {
                    didRestore = await restoreSavedItemOrder(
                        items,
                        hiddenControlItem: hiddenControlItem,
                        alwaysHiddenControlItem: alwaysHiddenControlItem
                    )
                }
                if didRestore {
                    scheduleRestoringRecache()
                    return
                }
                isRestoringItemOrder = false
                isRestoringItemOrderStartDate = nil
            }

            uncheckedCacheItems(
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem,
                otherItems: items
            )
            if !isRestoringItemOrder {
                saveSectionOrder(from: itemCache)
            }
        } catch {
            isRestoringItemOrder = false
            isRestoringItemOrderStartDate = nil
            Logger.itemManager.error("Error enforcing control item order: \(error)")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
        }
    }
}

// MARK: - Saved Section Order

extension MenuBarItemManager {
    /// The amount of time to wait before recaching after internal item moves.
    private static let uiSettleDelay: Duration = .milliseconds(300)

    /// The amount of time after an internal item move during which saved
    /// section restores are suppressed.
    private static let restoreCooldown: TimeInterval = 5

    /// Loads the persisted item order data.
    private func loadPersistedItemOrder() {
        if let stored = Defaults.dictionary(forKey: .savedSectionOrder) as? [String: [String]] {
            savedSectionOrder = stored
        }
        knownItemIdentifiers = Set(Defaults.stringArray(forKey: .knownItemIdentifiers) ?? [])
    }

    /// Persists the saved section order.
    private func persistSavedSectionOrder() {
        Defaults.set(savedSectionOrder, forKey: .savedSectionOrder)
    }

    /// Persists the known item identifiers.
    private func persistKnownItemIdentifiers() {
        Defaults.set(Array(knownItemIdentifiers), forKey: .knownItemIdentifiers)
    }

    /// Returns the persistable key for the given section name.
    private func sectionKey(for section: MenuBarSection.Name) -> String {
        switch section {
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }
    }

    /// Returns the section name for the given persistable key, if valid.
    private func sectionName(for key: String) -> MenuBarSection.Name? {
        switch key {
        case "visible": .visible
        case "hidden": .hidden
        case "alwaysHidden": .alwaysHidden
        default: nil
        }
    }

    /// Returns the stable identifier used to persist an item's section.
    private func stableIdentifier(for item: MenuBarItem) -> String {
        item.info.description
    }

    /// Returns the best-known bounds for a menu bar item.
    private func bestBounds(for item: MenuBarItem) -> CGRect {
        Bridging.getWindowFrame(for: item.windowID) ?? item.frame
    }

    /// Returns a Boolean value that indicates whether the app has performed
    /// an internal item move within the given time interval.
    private func ownMovesOccurred(within interval: TimeInterval) -> Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= interval
    }

    /// Returns a Boolean value that indicates whether previously seen item
    /// windows have disappeared, which indicates that apps have restarted.
    private func windowIDsDisappeared(_ items: [MenuBarItem], previousWindowIDs: [CGWindowID]) -> Bool {
        let currentWindowIDSet = Set(items.map(\.windowID))
        let previousWindowIDSet = Set(previousWindowIDs)
        return !previousWindowIDSet.isEmpty && !previousWindowIDSet.isSubset(of: currentWindowIDSet)
    }

    /// Returns the section the given item is physically in, or `nil` if the
    /// item straddles a control item boundary.
    private func findSection(
        for item: MenuBarItem,
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) -> MenuBarSection.Name? {
        let itemBounds = bestBounds(for: item)
        let hiddenBounds = bestBounds(for: hiddenControlItem)
        if itemBounds.minX >= hiddenBounds.maxX {
            return .visible
        }
        guard itemBounds.maxX <= hiddenBounds.minX else {
            return nil
        }
        if let alwaysHiddenControlItem {
            let alwaysHiddenBounds = bestBounds(for: alwaysHiddenControlItem)
            if itemBounds.maxX <= alwaysHiddenBounds.minX {
                return .alwaysHidden
            }
        }
        return .hidden
    }

    /// Returns the destination that places an item at the leftmost edge of
    /// the given section.
    private func moveDestination(
        for section: MenuBarSection.Name,
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) -> MoveDestination {
        switch section {
        case .visible:
            .rightOfItem(hiddenControlItem)
        case .hidden:
            if let alwaysHiddenControlItem {
                .rightOfItem(alwaysHiddenControlItem)
            } else {
                .leftOfItem(hiddenControlItem)
            }
        case .alwaysHidden:
            if let alwaysHiddenControlItem {
                .leftOfItem(alwaysHiddenControlItem)
            } else {
                .leftOfItem(hiddenControlItem)
            }
        }
    }

    /// Extracts the current per-section item order from the given cache and
    /// persists it. Entries for items that are not currently present (for
    /// example, items whose apps are closed) are preserved. Skips the write
    /// when the order has not changed.
    private func saveSectionOrder(from cache: ItemCache) {
        var newOrder = [String: [String]]()
        var currentIdentifiers = Set<String>()

        for section in MenuBarSection.Name.allCases {
            for item in cache[section] where !item.isIceControlItem {
                currentIdentifiers.insert(stableIdentifier(for: item))
            }
        }

        for section in MenuBarSection.Name.allCases {
            var identifiers = cache[section]
                .filter { !$0.isIceControlItem }
                .map { stableIdentifier(for: $0) }

            // Preserve saved entries for items that are not currently present,
            // so that their section is remembered while their apps are closed.
            if let savedIdentifiers = savedSectionOrder[sectionKey(for: section)] {
                for identifier in savedIdentifiers
                where !currentIdentifiers.contains(identifier) && !identifiers.contains(identifier) {
                    identifiers.append(identifier)
                }
            }

            if !identifiers.isEmpty {
                newOrder[sectionKey(for: section)] = identifiers
            }
        }

        guard newOrder != savedSectionOrder else {
            return
        }
        savedSectionOrder = newOrder
        persistSavedSectionOrder()
        Logger.itemManager.debug("Saved section order: \(newOrder.mapValues(\.count))")
    }

    /// Relocates brand-new items that macOS placed to the left of the hidden
    /// control item into the visible section, and keeps the Ice icon and
    /// non-hideable system items in the visible section.
    ///
    /// - Returns: `true` if an item was relocated; the caller should recache.
    private func relocateNewLeftmostItems(
        _ items: [MenuBarItem],
        hiddenControlItem: MenuBarItem
    ) async -> Bool {
        // On the first cache pass, seed the known identifiers so that the
        // baseline items aren't treated as new, then leave everything alone.
        if knownItemIdentifiers.isEmpty {
            knownItemIdentifiers = Set(items.filter { !$0.isIceControlItem }.map { stableIdentifier(for: $0) })
            persistKnownItemIdentifiers()
            return false
        }

        let hiddenBounds = bestBounds(for: hiddenControlItem)
        let leftmostItems = items
            .filter {
                $0.frame.maxX <= hiddenBounds.minX &&
                    $0.isMovable &&
                    (!$0.isIceControlItem || $0.info == .iceIcon)
            }
            .sorted { $0.frame.minX < $1.frame.minX }

        guard !leftmostItems.isEmpty else {
            return false
        }

        // The Ice icon must always appear in the visible section.
        if let iceIcon = leftmostItems.first(where: { $0.info == .iceIcon }) {
            Logger.itemManager.info("Relocating Ice icon \(iceIcon.logString) to the visible section")
            do {
                try await slowMove(item: iceIcon, to: .rightOfItem(hiddenControlItem))
                return true
            } catch {
                Logger.itemManager.error("Failed to relocate Ice icon \(iceIcon.logString): \(error)")
                return false
            }
        }

        // Non-hideable system items must always appear in the visible section.
        if let systemItem = leftmostItems.first(where: { !$0.canBeHidden }) {
            Logger.itemManager.info("Relocating non-hideable system item \(systemItem.logString) to the visible section")
            do {
                try await slowMove(item: systemItem, to: .rightOfItem(hiddenControlItem))
                return true
            } catch {
                Logger.itemManager.error("Failed to relocate system item \(systemItem.logString): \(error)")
                return false
            }
        }

        // Items that are already cached in the hidden or always-hidden sections
        // are there intentionally; leave them alone.
        let hiddenInfos = Set(itemCache[.hidden].map(\.info))
        let alwaysHiddenInfos = Set(itemCache[.alwaysHidden].map(\.info))
        let savedIdentifiers = Set(savedSectionOrder.values.flatMap { $0 })

        // Find a hideable item that is genuinely new and has no saved section;
        // items with saved sections are handled by the restore pass.
        let candidate = leftmostItems.first { item in
            let identifier = stableIdentifier(for: item)
            guard !savedIdentifiers.contains(identifier) else {
                return false
            }
            guard !hiddenInfos.contains(item.info), !alwaysHiddenInfos.contains(item.info) else {
                return false
            }
            return !knownItemIdentifiers.contains(identifier)
        }

        guard let candidate else {
            return false
        }

        knownItemIdentifiers.insert(stableIdentifier(for: candidate))
        persistKnownItemIdentifiers()

        Logger.itemManager.info("Relocating new item \(candidate.logString) to the visible section")
        do {
            try await slowMove(item: candidate, to: .rightOfItem(hiddenControlItem))
            return true
        } catch {
            Logger.itemManager.error("Failed to relocate \(candidate.logString): \(error)")
            return false
        }
    }

    /// Moves items back to their saved sections after their apps restart and
    /// macOS places them somewhere else. Only one item is moved per call; the
    /// caller should recache when `true` is returned.
    private func restoreItemsToSavedSections(
        _ items: [MenuBarItem],
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) async -> Bool {
        guard !savedSectionOrder.isEmpty else {
            return false
        }

        // Build a lookup from stable identifiers to their saved sections.
        var savedSectionForIdentifier = [String: MenuBarSection.Name]()
        for (sectionKeyString, identifiers) in savedSectionOrder {
            guard let section = sectionName(for: sectionKeyString) else {
                continue
            }
            for identifier in identifiers {
                savedSectionForIdentifier[identifier] = section
            }
        }

        // Don't interfere with temporarily shown items.
        let tempShownInfos = Set(tempShownItemContexts.map(\.info))

        // Count items per namespace so that items from apps with multiple icons
        // can be skipped; restoring them causes shuffling, as the icons
        // naturally position themselves together.
        var infosPerNamespace = [MenuBarItemInfo.Namespace: Int]()
        for item in items where !item.isIceControlItem && item.isMovable && item.canBeHidden {
            infosPerNamespace[item.info.namespace, default: 0] += 1
        }

        for item in items where !item.isIceControlItem && item.isMovable && item.canBeHidden {
            guard !tempShownInfos.contains(item.info) else {
                continue
            }
            guard infosPerNamespace[item.info.namespace] == 1 else {
                continue
            }
            guard
                let savedSection = savedSectionForIdentifier[stableIdentifier(for: item)],
                let currentSection = findSection(
                    for: item,
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                ),
                currentSection != savedSection
            else {
                continue
            }

            let destination = moveDestination(
                for: savedSection,
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem
            )
            Logger.itemManager.info("Restoring \(item.logString) from the \(currentSection.logString) to the \(savedSection.logString)")
            do {
                try await slowMove(item: item, to: destination)
            } catch {
                Logger.itemManager.error("Failed to restore \(item.logString) to the \(savedSection.logString): \(error)")
                continue
            }

            // Move one item per pass, letting macOS settle before the next.
            return true
        }

        return false
    }

    /// Restores the saved order of items within each section after their apps
    /// restart and macOS places them somewhere else.
    ///
    /// - Returns: `true` if any items were moved; the caller should recache.
    private func restoreSavedItemOrder(
        _ items: [MenuBarItem],
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?
    ) async -> Bool {
        guard !savedSectionOrder.isEmpty else {
            return false
        }

        // Skip items from apps with multiple icons; they naturally position
        // themselves, and restoring their order causes shuffling.
        var infosPerNamespace = [MenuBarItemInfo.Namespace: Int]()
        for item in items where !item.isIceControlItem && item.isMovable && item.canBeHidden {
            infosPerNamespace[item.info.namespace, default: 0] += 1
        }
        guard !infosPerNamespace.values.contains(where: { $0 > 1 }) else {
            return false
        }

        // Don't interfere with temporarily shown items.
        let tempShownInfos = Set(tempShownItemContexts.map(\.info))

        // Classify the current items into sections, preserving their order,
        // which runs from left to right in the menu bar.
        var currentSectionItems = [String: [MenuBarItem]]()
        for item in items where !item.isIceControlItem && item.isMovable && item.canBeHidden {
            guard !tempShownInfos.contains(item.info) else {
                continue
            }
            if let section = findSection(
                for: item,
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem
            ) {
                currentSectionItems[sectionKey(for: section), default: []].append(item)
            }
        }

        var itemsByID = [String: MenuBarItem]()
        for item in items where !item.isIceControlItem {
            itemsByID[stableIdentifier(for: item)] = item
        }

        var didMove = false

        for section in MenuBarSection.Name.allCases {
            guard
                let savedIdentifiers = savedSectionOrder[sectionKey(for: section)],
                let currentItems = currentSectionItems[sectionKey(for: section)],
                !currentItems.isEmpty
            else {
                continue
            }

            // Only consider saved identifiers that are present in this section
            // right now, and skip the section if their relative order already
            // matches the saved order.
            let currentIdentifiers = currentItems.map { stableIdentifier(for: $0) }
            let currentIdentifierSet = Set(currentIdentifiers)
            let filteredSaved = savedIdentifiers.filter { currentIdentifierSet.contains($0) }
            let filteredSavedSet = Set(filteredSaved)
            guard
                !filteredSaved.isEmpty,
                currentIdentifiers.filter({ filteredSavedSet.contains($0) }) != filteredSaved
            else {
                continue
            }

            Logger.itemManager.info("Restoring saved item order for the \(section.logString) (\(filteredSaved.count) items)")

            // The saved order runs from left to right, so the first item is the
            // anchor; each subsequent item is placed to its right.
            guard let anchor = itemsByID[filteredSaved[0]] else {
                continue
            }

            var currentAnchor = anchor
            for identifier in filteredSaved.dropFirst() {
                guard let item = itemsByID[identifier] else {
                    continue
                }
                do {
                    try await slowMove(item: item, to: .rightOfItem(currentAnchor))
                    didMove = true
                    // Only advance the anchor after a successful move so that
                    // the next item targets the last correctly placed position.
                    currentAnchor = item
                } catch {
                    Logger.itemManager.error("Failed to restore position for \(item.logString) in the \(section.logString): \(error)")
                }
            }
        }

        return didMove
    }

    /// Schedules a forced recache after a short settling delay, so that macOS
    /// has time to apply internal item moves before the cache is updated again.
    private func scheduleRestoringRecache() {
        Task { [weak self] in
            try? await Task.sleep(for: MenuBarItemManager.uiSettleDelay)
            guard let self else {
                return
            }
            await cacheItemsIfNeeded(force: true)
        }
    }
}

// MARK: - MenuBarItem Control Info

private extension MenuBarItem {
    /// A Boolean value that indicates whether the item is one of Ice's control items.
    var isIceControlItem: Bool {
        info == .iceIcon || info == .hiddenControlItem || info == .alwaysHiddenControlItem
    }
}

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete
            /// The creation of a menu bar item event failed.
            case eventCreationFailure
            /// The shared app state is invalid or could not be found.
            case invalidAppState
            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource
            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation
            /// A menu bar item is invalid.
            case invalidItem
            /// A menu bar item cannot be moved.
            case notMovable
            /// A menu bar item event operation timed out.
            case eventOperationTimeout
            /// A menu bar item frame check timed out.
            case frameCheckTimeout
            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                "Could not complete event operation for \"\(item.displayName)\""
            case .eventCreationFailure:
                "Failed to create event for \"\(item.displayName)\""
            case .invalidAppState:
                "Invalid app state for \"\(item.displayName)\""
            case .invalidEventSource:
                "Invalid event source for \"\(item.displayName)\""
            case .invalidCursorLocation:
                "Invalid cursor location for \"\(item.displayName)\""
            case .invalidItem:
                "\"\(item.displayName)\" is invalid"
            case .notMovable:
                "\"\(item.displayName)\" is not movable"
            case .eventOperationTimeout:
                "Event operation timed out for \"\(item.displayName)\""
            case .frameCheckTimeout:
                "Frame check timed out for \"\(item.displayName)\""
            case .otherTimeout:
                "Operation timed out for \"\(item.displayName)\""
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            "Please try again. If the error persists, please file a bug report."
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        let taskBody: @Sendable () async throws -> Void = {
            while await self.isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let checkTask = if let timeout {
            Task(timeout: timeout) {
                try await taskBody()
            }
        } else {
            Task {
                try await taskBody()
            }
        }
        try await checkTask.value
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        let taskBody: @Sendable () async throws -> Void = {
            while true {
                try Task.checkCancellation()
                guard let date = await self.lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let checkTask = if let timeout {
            Task(timeout: timeout) {
                try await taskBody()
            }
        } else {
            Task {
                try await taskBody()
            }
        }
        try await checkTask.value
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item):
                "left of \(item.logString)"
            case .rightOfItem(let item):
                "right of \(item.logString)"
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        guard let frame = Bridging.getWindowFrame(for: item.window.windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    private func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.minX, y: currentFrame.midY)
        case .rightOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.maxX, y: currentFrame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    private func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.maxX == currentTargetFrame.minX
        case .rightOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return currentFrame.minX == currentTargetFrame.maxX
        }
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    private func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            postEvent(event, to: location)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let userData: Int64 = 0x1CE
        nullEvent.setIntegerValueField(.eventSourceUserData, value: userData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location that throws away
            // all events it receives. Once the null event is received, post the real event
            // to the second location.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == userData else {
                    return nil
                }

                proxy.disable()
                postEvent(event, to: secondLocation)

                return nil
            }

            // Create an event tap for the real event at the second location that can listen
            // for events but not alter or discard them. Once the event is received, post it
            // to the first location.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem
    ) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    private func waitForFrameChange(
        of item: MenuBarItem,
        initialFrame: CGRect,
        timeout: Duration
    ) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    private func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    private func wakeUpItem(_ item: MenuBarItem) async throws {
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    private func moveItemWithoutRestoringMouseLocation(
        _ item: MenuBarItem,
        to destination: MoveDestination
    ) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = try getEndPoint(for: destination)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: endPoint,
                item: targetItem,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        lastItemMoveStartDate = .now

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if try itemHasCorrectPosition(item: item, for: destination) {
            Logger.itemManager.debug("\(item.logString) is already in the correct position")
            return
        }

        do {
            try await waitForMouseToStopMoving()
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }

        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.location(in: .coreGraphics) else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let initialFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Item movement can occasionally fail. Retry up to a total of 5 attempts,
        // throwing the last attempt's error if it fails.
        for n in 1...5 {
            do {
                try await moveItemWithoutRestoringMouseLocation(item, to: destination)
                guard let newFrame = getCurrentFrame(for: item) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if newFrame != initialFrame {
                    Logger.itemManager.info("Successfully moved \(item.logString)")
                    break
                } else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
            } catch where n < 5 {
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                try await wakeUpItem(item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
                continue
            }
        }
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    /// 
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1)) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        try await move(item: item, to: destination)
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if try await self.itemHasCorrectPosition(item: item, for: destination) {
                    return
                }
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Clicks the given menu bar item with the given button states.
    private func click(
        item: MenuBarItem,
        mouseDownButtonState: CGEvent.MenuBarItemEventButtonState,
        mouseUpButtonState: CGEvent.MenuBarItemEventButtonState
    ) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.location(in: .coreGraphics) else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseDownButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseUpButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseUpButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            try await postEventAndWaitToReceive(
                mouseDownEvent,
                to: .sessionEventTap,
                item: item
            )
            try await postEventAndWaitToReceive(
                mouseUpEvent,
                to: .sessionEventTap,
                item: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for clicking \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for clicking \(item.logString)")
            }
            throw error
        }
    }

    /// Clicks the given menu bar item with the given mouse button.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        Logger.itemManager.info("Clicking \(item.logString) with \(mouseButton.logString)")
        try await click(
            item: item,
            mouseDownButtonState: mouseButton.downState,
            mouseUpButtonState: mouseButton.upState
        )
    }
}

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the destination to return the given item to after it is temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        let info = item.info
        if let index = items.firstIndex(where: { $0.info == info }) {
            if items.indices.contains(index + 1) {
                return .leftOfItem(items[index + 1])
            } else if items.indices.contains(index - 1) {
                return .rightOfItem(items[index - 1])
            }
        }
        return nil
    }

    /// Schedules a timer for the given interval, attempting to rehide the current
    /// temporarily shown items when the timer fires.
    private func runTempShownItemTimer(for interval: TimeInterval) {
        Logger.itemManager.debug("Running rehide timer for temporarily shown items with interval: \(interval)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Logger.itemManager.debug("Rehide timer fired")
            Task {
                await self.rehideTempShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached alongside a destination that it will be automatically
    /// returned to. If `true` is passed to the `clickWhenFinished` parameter, the
    /// item is clicked once movement is finished.
    ///
    /// - Parameters:
    ///   - item: An item to show.
    ///   - clickWhenFinished: A Boolean value that indicates whether the item should
    ///     be clicked once movement has finished.
    ///   - mouseButton: The mouse button of the click.
    func tempShowItem(
        _ item: MenuBarItem,
        clickWhenFinished: Bool,
        mouseButton: CGMouseButton
    ) {
        if
            let latest = MenuBarItem(windowID: item.windowID),
            latest.isOnScreen
        {
            if clickWhenFinished {
                Task {
                    do {
                        try await click(item: latest, with: mouseButton)
                    } catch {
                        Logger.itemManager.error("ERROR: \(error)")
                    }
                }
            }
            return
        }

        guard
            let appState,
            let screen = NSScreen.main,
            let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            Logger.itemManager.warning("No application menu frame, so not showing \(item.logString)")
            return
        }

        Logger.itemManager.info("Temporarily showing \(item.logString)")

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        guard let destination = getReturnDestination(for: item, in: items) else {
            Logger.itemManager.warning("No return destination for \(item.logString)")
            return
        }

        // Remove all items up to the hidden control item.
        items.trimPrefix { $0.info != .hiddenControlItem }
        // Remove the hidden control item.
        items.removeFirst()
        // Remove all offscreen items.
        items.trimPrefix { !$0.isOnScreen }

        let maxX = if let rightArea = screen.auxiliaryTopRightArea {
            max(rightArea.minX + 20, applicationMenuFrame.maxX)
        } else {
            applicationMenuFrame.maxX
        }

        // Remove items until we have enough room to show this item.
        items.trimPrefix { $0.frame.minX - item.frame.width <= maxX }

        guard let targetItem = items.first else {
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        let initialWindows = WindowInfo.getOnScreenWindows()

        Task {
            if clickWhenFinished {
                do {
                    try await slowMove(item: item, to: .leftOfItem(targetItem))
                    try await click(item: item, with: mouseButton)
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            } else {
                do {
                    try await move(item: item, to: .leftOfItem(targetItem))
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(100))

            let currentWindows = WindowInfo.getOnScreenWindows()

            let shownInterfaceWindow = currentWindows.first { currentWindow in
                currentWindow.ownerPID == item.ownerPID &&
                !initialWindows.contains { initialWindow in
                    currentWindow.windowID == initialWindow.windowID
                }
            }

            let context = TempShownItemContext(
                info: item.info,
                returnDestination: destination,
                shownInterfaceWindow: shownInterfaceWindow
            )
            tempShownItemContexts.append(context)
            runTempShownItemTimer(for: appState.settingsManager.advancedSettingsManager.tempShowInterval)
        }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    func rehideTempShownItems() async {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard !tempShownItemContexts.isEmpty else {
            return
        }

        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            Logger.itemManager.debug("Menu bar item interface is shown, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }

        Logger.itemManager.info("Rehiding temporarily shown items")

        var failedContexts = [TempShownItemContext]()

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        while let context = tempShownItemContexts.popLast() {
            guard let item = items.first(where: { $0.info == context.info }) else {
                continue
            }
            do {
                try await move(item: item, to: context.returnDestination)
            } catch {
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
                failedContexts.append(context)
            }
        }

        if failedContexts.isEmpty {
            tempShownItemsTimer?.invalidate()
            tempShownItemsTimer = nil
        } else {
            tempShownItemContexts = failedContexts
            Logger.itemManager.warning("Some items failed to rehide")
            runTempShownItemTimer(for: 3)
        }
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(with info: MenuBarItemInfo) {
        tempShownItemContexts.removeAll { $0.info == info }
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for
    ///     the hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem
    ) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Button states for menu bar item events.
    enum MenuBarItemEventButtonState {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp
    }

    /// Event types for menu bar item events.
    enum MenuBarItemEventType {
        /// The event type for moving a menu bar item.
        case move(MenuBarItemEventButtonState)
        /// The event type for clicking a menu bar item.
        case click(MenuBarItemEventButtonState)

        /// The button state of this event type.
        var buttonState: MenuBarItemEventButtonState {
            switch self {
            case .move(let state), .click(let state): state
            }
        }

        /// This event type's equivalent CGEventType.
        var cgEventType: CGEventType {
            switch buttonState {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        /// The event flags for this event type.
        var cgEventFlags: CGEventFlags {
            switch self {
            case .move(.leftMouseDown): .maskCommand
            case .move, .click: []
            }
        }

        /// The mouse button for this event type.
        var mouseButton: CGMouseButton {
            switch buttonState {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }
    }

    /// A context that manages the user data for menu bar item events.
    enum MenuBarItemEventUserDataContext {
        /// The internal state of the context.
        private static var state: Int64 = 0x1CE

        /// Returns the current user data and increments the internal state.
        static func next() -> Int64 {
            defer { state += 1 }
            return state
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the window number of the event.
    static let windowNumber = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare two menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowNumber,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The menu bar item event state for when this mouse button is down.
    var downState: CGEvent.MenuBarItemEventButtonState {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        case .center:
            return .otherMouseDown
        @unknown default:
            fatalError("Unknown mouse button \(rawValue)")
        }
    }

    /// The menu bar item event state for when this mouse button is up.
    var upState: CGEvent.MenuBarItemEventButtonState {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        case .center:
            return .otherMouseUp
        @unknown default:
            fatalError("Unknown mouse button \(rawValue)")
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(
        type: MenuBarItemEventType,
        location: CGPoint,
        item: MenuBarItem,
        pid: pid_t,
        source: CGEventSource
    ) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: mouseType,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = MenuBarItemEventUserDataContext.next()
        let windowNumber = Int64(item.windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowNumber)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowNumber)
        event.setIntegerValueField(.windowNumber, value: windowNumber)

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}
