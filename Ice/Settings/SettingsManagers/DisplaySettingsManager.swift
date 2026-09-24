//
//  DisplaySettingsManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for per-display settings.
///
/// Configurations are keyed by display UUID string (via
/// `Bridging.getDisplayUUIDString(for:)`). When a display has no explicit
/// configuration, ``DisplayIceBarConfiguration/defaultConfiguration`` is
/// returned.
@MainActor
final class DisplaySettingsManager: ObservableObject {
    /// Per-display configurations, keyed by display UUID string.
    @Published var configurations: [String: DisplayIceBarConfiguration] = [:]

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// JSON encoder for persistence.
    private let encoder = JSONEncoder()

    /// JSON decoder for persistence.
    private let decoder = JSONDecoder()

    /// The shared app state.
    private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Performs the initial setup of the manager.
    func performSetup() {
        loadInitialState()
        configureCancellables()
    }

    // MARK: - Loading

    /// Loads saved configurations from Defaults.
    private func loadInitialState() {
        guard let data = Defaults.data(forKey: .displayIceBarConfigurations) else {
            return
        }
        do {
            configurations = try decoder.decode([String: DisplayIceBarConfiguration].self, from: data)
            Logger.displaySettingsManager.info("Loaded per-display configurations for \(configurations.count) display(s)")
        } catch {
            Logger.displaySettingsManager.error("Error decoding per-display configurations: \(error)")
        }
    }

    // MARK: - Persistence

    /// Configures Combine sinks to persist configurations on change.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $configurations
            .dropFirst() // Skip the initial emission during setup
            .receive(on: DispatchQueue.main)
            .sink { configs in
                do {
                    let data = try JSONEncoder().encode(configs)
                    Defaults.set(data, forKey: .displayIceBarConfigurations)
                } catch {
                    Logger.displaySettingsManager.error("Error encoding per-display configurations: \(error)")
                }
            }
            .store(in: &c)

        // Listen for display connect/disconnect to log changes.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Logger.displaySettingsManager.info("Screen parameters changed — \(NSScreen.screens.count) screen(s) connected")
            }
            .store(in: &c)

        cancellables = c
    }

    // MARK: - Lookup

    /// Returns the configuration for the given display.
    func configuration(for displayID: CGDirectDisplayID) -> DisplayIceBarConfiguration {
        guard let uuid = Bridging.getDisplayUUIDString(for: displayID) else {
            return .defaultConfiguration
        }
        return configurations[uuid] ?? .defaultConfiguration
    }

    /// Returns the configuration for the display with the active menu bar.
    func configurationForActiveDisplay() -> DisplayIceBarConfiguration {
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else {
            return .defaultConfiguration
        }
        return configuration(for: displayID)
    }

    /// Returns a Boolean value that indicates whether the Ice Bar is
    /// enabled for the given display.
    func useIceBar(for displayID: CGDirectDisplayID) -> Bool {
        configuration(for: displayID).useIceBar
    }

    /// Returns the Ice Bar location for the given display.
    func iceBarLocation(for displayID: CGDirectDisplayID) -> IceBarLocation {
        configuration(for: displayID).iceBarLocation
    }

    /// Returns a Boolean value that indicates whether hidden items should
    /// always be shown for the given display.
    func alwaysShowHiddenItems(for displayID: CGDirectDisplayID) -> Bool {
        configuration(for: displayID).alwaysShowHiddenItems
    }

    /// A Boolean value that indicates whether the Ice Bar is enabled on
    /// any configured display.
    var isIceBarEnabledOnAnyDisplay: Bool {
        configurations.values.contains { $0.useIceBar }
    }

    /// A Boolean value that indicates whether "Always show hidden items"
    /// is enabled on any configured display.
    var isAlwaysShowEnabledOnAnyDisplay: Bool {
        configurations.values.contains { $0.alwaysShowHiddenItems }
    }

    // MARK: - Mutation (Immutable Pattern)

    /// Updates the configuration for a display by applying a transform,
    /// producing a new dictionary (immutable pattern).
    func updateConfiguration(
        forDisplayUUID uuid: String,
        transform: (DisplayIceBarConfiguration) -> DisplayIceBarConfiguration
    ) {
        let current = configurations[uuid] ?? .defaultConfiguration
        let updated = transform(current)
        var newConfigurations = configurations
        newConfigurations[uuid] = updated
        configurations = newConfigurations
    }

    /// Toggles the Ice Bar for the display with the active menu bar.
    func toggleIceBarForActiveDisplay() {
        guard let uuid = Bridging.getActiveMenuBarDisplayUUID() else {
            Logger.displaySettingsManager.warning("Cannot toggle Ice Bar — no active menu bar display UUID")
            return
        }
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withUseIceBar(!config.useIceBar)
        }
    }

    // MARK: - Display Info

    /// Information about a connected display for use in the settings interface.
    struct DisplayInfo: Identifiable {
        let id: String // UUID string
        let displayID: CGDirectDisplayID
        let name: String
        let hasNotch: Bool
    }

    /// Returns information about all currently connected displays.
    func connectedDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else {
                return nil
            }
            return DisplayInfo(
                id: uuid,
                displayID: screen.displayID,
                name: screen.localizedName,
                hasNotch: screen.hasNotch
            )
        }
    }
}

// MARK: - Logger
private extension Logger {
    /// Logger to use for the display settings manager.
    static let displaySettingsManager = Logger(category: "DisplaySettingsManager")
}
