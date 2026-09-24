//
//  OnKeyDown.swift
//  Ice
//

import SwiftUI

extension View {
    /// Returns a view that performs the given action when
    /// the specified key is pressed.
    func onKeyDown(key: KeyCode, action: @escaping () -> Void) -> some View {
        localEventMonitor(mask: .keyDown) { event in
            if event.keyCode == key.rawValue {
                action()
                return nil
            }
            return event
        }
    }

    /// Returns a view that performs the given action when the specified
    /// key is pressed with exactly the given modifier flags.
    ///
    /// The event is consumed when the action is performed, preventing
    /// other responders -- such as a focused text field's key bindings --
    /// from handling it.
    ///
    /// - Parameters:
    ///   - key: The key that must be pressed.
    ///   - modifiers: The modifier flags that must be pressed with the key.
    ///     The event's device-independent modifier flags must match these
    ///     exactly for the action to be performed.
    ///   - action: The action to perform when the key is pressed.
    func onKeyDown(key: KeyCode, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) -> some View {
        localEventMonitor(mask: .keyDown) { event in
            if
                event.keyCode == key.rawValue,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
            {
                action()
                return nil
            }
            return event
        }
    }
}
