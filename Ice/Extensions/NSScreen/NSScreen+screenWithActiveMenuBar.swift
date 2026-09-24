//
//  NSScreen+screenWithActiveMenuBar.swift
//  Ice
//

import AppKit

extension NSScreen {
    /// The screen that contains the active menu bar.
    static var screenWithActiveMenuBar: NSScreen? {
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else {
            return nil
        }
        return screens.first { $0.displayID == displayID }
    }
}
