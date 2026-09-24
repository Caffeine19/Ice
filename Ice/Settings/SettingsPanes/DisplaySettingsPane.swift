//
//  DisplaySettingsPane.swift
//  Ice
//

import SwiftUI

struct DisplaySettingsPane: View {
    @EnvironmentObject var appState: AppState

    private var manager: DisplaySettingsManager {
        appState.settingsManager.displaySettingsManager
    }

    var body: some View {
        IceForm {
            ForEach(manager.connectedDisplays()) { display in
                IceSection {
                    displayRow(for: display)
                }
            }
        }
    }

    @ViewBuilder
    private func displayRow(for display: DisplaySettingsManager.DisplayInfo) -> some View {
        let useIceBar = Binding<Bool>(
            get: { manager.configuration(for: display.displayID).useIceBar },
            set: { newValue in
                manager.updateConfiguration(forDisplayUUID: display.id) { config in
                    config.withUseIceBar(newValue)
                }
            }
        )

        let location = Binding<IceBarLocation>(
            get: { manager.configuration(for: display.displayID).iceBarLocation },
            set: { newValue in
                manager.updateConfiguration(forDisplayUUID: display.id) { config in
                    config.withIceBarLocation(newValue)
                }
            }
        )

        let alwaysShowHiddenItems = Binding<Bool>(
            get: { manager.configuration(for: display.displayID).alwaysShowHiddenItems },
            set: { newValue in
                manager.updateConfiguration(forDisplayUUID: display.id) { config in
                    config.withAlwaysShowHiddenItems(newValue)
                }
            }
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                    .font(.headline)
                if display.hasNotch {
                    Text("Notch")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }

        Toggle("Always show hidden items", isOn: alwaysShowHiddenItems)
            .disabled(useIceBar.wrappedValue)
            .annotation {
                if useIceBar.wrappedValue {
                    Text("Not available because the Ice Bar is enabled for this display.")
                } else {
                    Text("Always show hidden menu bar items in the menu bar on this display.")
                }
            }

        Toggle("Use Ice Bar", isOn: useIceBar)
            .annotation("Show hidden menu bar items in a separate bar below the menu bar on this display.")

        if useIceBar.wrappedValue {
            IcePicker("Location", selection: location) {
                ForEach(IceBarLocation.allCases) { loc in
                    Text(loc.localized).icePickerID(loc)
                }
            }
            .annotation {
                switch location.wrappedValue {
                case .dynamic:
                    Text("The Ice Bar's location changes based on context.")
                case .mousePointer:
                    Text("The Ice Bar is centered below the mouse pointer.")
                case .iceIcon:
                    Text("The Ice Bar is centered below the Ice icon.")
                }
            }
        }
    }
}
