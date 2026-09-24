//
//  MenuBarSection.swift
//  Ice
//

import Cocoa

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: UniversalEventMonitor?

    /// A Boolean value that indicates whether the Ice Bar should be used
    /// on the target display.
    private var useIceBar: Bool {
        guard let appState else {
            return false
        }
        let screen = screenForIceBar
        let displayID = screen?.displayID ?? CGMainDisplayID()
        return appState.settingsManager.displaySettingsManager.useIceBar(for: displayID)
    }

    /// A weak reference to the menu bar manager's Ice Bar panel.
    private weak var iceBarPanel: IceBarPanel? {
        appState?.menuBarManager.iceBarPanel
    }

    /// The best screen to show the Ice Bar on.
    ///
    /// Prefers the screen with the active menu bar so that clicking items
    /// in the Ice Bar activates their popups.
    private weak var screenForIceBar: NSScreen? {
        guard let appState else {
            return nil
        }
        if appState.isActiveSpaceFullscreen {
            return NSScreen.screenWithMouse ?? NSScreen.main
        } else {
            return NSScreen.screenWithActiveMenuBar ?? NSScreen.main
        }
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useIceBar {
            if controlItem.state == .showItems {
                return false
            }
            switch name {
            case .visible, .hidden:
                return iceBarPanel?.currentSection != .hidden
            case .alwaysHidden:
                return iceBarPanel?.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if iceBarPanel?.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideItems
        case .alwaysHidden:
            if iceBarPanel?.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideItems
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if case .visible = name {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// The hiding state the user desires for the section.
    ///
    /// This is the source of truth for the section's hiding state; the
    /// control item's state is derived from it by ``updateControlItemState(for:)``,
    /// which applies the per-display "Always show hidden items" override.
    private(set) var desiredState: ControlItem.HidingState

    /// Sets the desired hiding state and updates the control item.
    ///
    /// - Parameters:
    ///   - state: The desired hiding state.
    ///   - screen: The screen to use for the update. If `nil`, the best
    ///     screen is determined automatically.
    func setDesiredState(_ state: ControlItem.HidingState, for screen: NSScreen? = nil) {
        desiredState = state
        updateControlItemState(for: screen)
    }

    /// Updates the state of the control item based on the desired state
    /// and the current display configuration.
    ///
    /// - Parameter screen: The screen to use for the update. If `nil`, the
    ///   best screen is determined automatically.
    func updateControlItemState(for screen: NSScreen? = nil) {
        guard let appState else {
            return
        }

        // If the user wants to show, always show.
        if desiredState == .showItems {
            controlItem.state = .showItems
            return
        }

        // If the user wants to hide, check the current display configuration.
        // Use screenWithMouse for instant reactivity when switching displays.
        guard let activeScreen = screen ?? NSScreen.screenWithMouse ?? NSScreen.screenWithActiveMenuBar ?? NSScreen.main else {
            controlItem.state = desiredState
            return
        }

        let displaySettings = appState.settingsManager.displaySettingsManager
        let alwaysShow = displaySettings.alwaysShowHiddenItems(for: activeScreen.displayID)
        let useIceBar = displaySettings.useIceBar(for: activeScreen.displayID)

        if name == .hidden || name == .visible, alwaysShow, !useIceBar {
            controlItem.state = .showItems
        } else {
            controlItem.state = desiredState
        }
    }

    /// Creates a section with the given name, control item, and app state.
    init(name: Name, controlItem: ControlItem, appState: AppState) {
        self.name = name
        self.controlItem = controlItem
        self.appState = appState
        self.desiredState = controlItem.state
    }

    /// Creates a section with the given name and app state.
    convenience init(name: Name, appState: AppState) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .iceIcon, appState: appState)
        case .hidden:
            ControlItem(identifier: .hidden, appState: appState)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden, appState: appState)
        }
        self.init(name: name, controlItem: controlItem, appState: appState)
    }

    /// Shows the section.
    func show() {
        guard
            let appState,
            isHidden
        else {
            return
        }
        guard controlItem.isAddedToMenuBar else {
            // The section is disabled.
            // TODO: Can we use isEnabled for this check?
            return
        }
        switch name {
        case .visible where useIceBar, .hidden where useIceBar:
            Task {
                if let screenForIceBar {
                    await iceBarPanel?.show(section: .hidden, on: screenForIceBar)
                }
                for section in appState.menuBarManager.sections {
                    section.setDesiredState(.hideItems)
                }
            }
        case .alwaysHidden where useIceBar:
            Task {
                if let screenForIceBar {
                    await iceBarPanel?.show(section: .alwaysHidden, on: screenForIceBar)
                }
                for section in appState.menuBarManager.sections {
                    section.setDesiredState(.hideItems)
                }
            }
        case .visible:
            iceBarPanel?.close()
            guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
                return
            }
            setDesiredState(.showItems)
            hiddenSection.setDesiredState(.showItems)
        case .hidden:
            iceBarPanel?.close()
            guard let visibleSection = appState.menuBarManager.section(withName: .visible) else {
                return
            }
            setDesiredState(.showItems)
            visibleSection.setDesiredState(.showItems)
        case .alwaysHidden:
            iceBarPanel?.close()
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let visibleSection = appState.menuBarManager.section(withName: .visible)
            else {
                return
            }
            setDesiredState(.showItems)
            hiddenSection.setDesiredState(.showItems)
            visibleSection.setDesiredState(.showItems)
        }
        startRehideChecks()
    }

    /// Hides the section.
    func hide() {
        guard
            let appState,
            !isHidden
        else {
            return
        }
        iceBarPanel?.close()
        switch name {
        case _ where useIceBar:
            for section in appState.menuBarManager.sections {
                section.setDesiredState(.hideItems)
            }
        case .visible:
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            setDesiredState(.hideItems)
            hiddenSection.setDesiredState(.hideItems)
            alwaysHiddenSection.setDesiredState(.hideItems)
        case .hidden:
            guard
                let visibleSection = appState.menuBarManager.section(withName: .visible),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            setDesiredState(.hideItems)
            visibleSection.setDesiredState(.hideItems)
            alwaysHiddenSection.setDesiredState(.hideItems)
        case .alwaysHidden:
            setDesiredState(.hideItems)
        }
        appState.allowShowOnHover()
        stopRehideChecks()
    }

    /// Toggles the visibility of the section.
    func toggle() {
        if isHidden {
            show()
        } else {
            hide()
        }
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settingsManager.generalSettingsManager.autoRehide,
            case .timed = appState.settingsManager.generalSettingsManager.rehideStrategy
        else {
            return
        }

        rehideMonitor = UniversalEventMonitor(mask: .mouseMoved) { [weak self] event in
            guard
                let self,
                let screen = NSScreen.main
            else {
                return event
            }
            if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                if rehideTimer == nil {
                    rehideTimer = .scheduledTimer(
                        withTimeInterval: appState.settingsManager.generalSettingsManager.rehideInterval,
                        repeats: false
                    ) { [weak self] _ in
                        guard
                            let self,
                            let screen = NSScreen.main
                        else {
                            return
                        }
                        if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                            Task {
                                await self.hide()
                            }
                        } else {
                            Task {
                                await self.startRehideChecks()
                            }
                        }
                    }
                }
            } else {
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
            return event
        }

        rehideMonitor?.start()
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}

// MARK: MenuBarSection: BindingExposable
extension MenuBarSection: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarSection = Logger(category: "MenuBarSection")
}
