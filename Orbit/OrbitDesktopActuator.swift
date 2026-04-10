import AppKit
import Carbon.HIToolbox
import Foundation

enum OrbitDesktopActionConfidence: String, Codable {
    case high
    case medium
    case low
}

enum OrbitDesktopActionKind: String, Codable {
    case move
    case click
    case doubleClick
    case rightClick
    case typeText
    case pressKey
}

struct OrbitDesktopActionStep: Codable, Equatable {
    let kind: OrbitDesktopActionKind
    let x: Double?
    let y: Double?
    let screen: Int?
    let label: String?
    let text: String?
    let key: String?
}

struct OrbitDesktopActuationIntent: Codable, Equatable {
    let confidence: OrbitDesktopActionConfidence
    let steps: [OrbitDesktopActionStep]
}

extension OrbitDesktopActionStep {
    var imagePoint: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }

    var previewLabel: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }

        switch kind {
        case .move:
            return "moving to the next control."
        case .click:
            return "about to click here."
        case .doubleClick:
            return "about to double-click here."
        case .rightClick:
            return "about to open the menu here."
        case .typeText:
            return "about to type here."
        case .pressKey:
            return "about to press \(key ?? "a shortcut")."
        }
    }

    var executionLabel: String {
        switch kind {
        case .move:
            return "moving the pointer."
        case .click:
            return "clicking here."
        case .doubleClick:
            return "double-clicking here."
        case .rightClick:
            return "opening the context menu."
        case .typeText:
            return "typing into the focused target."
        case .pressKey:
            return "pressing \(key ?? "the shortcut")."
        }
    }
}

enum OrbitDesktopActuatorError: LocalizedError {
    case missingCoordinate
    case missingText
    case missingKey
    case unsupportedKey(String)
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingCoordinate:
            return "Orbit could not resolve the desktop target coordinates."
        case .missingText:
            return "Orbit needs text before it can type into the current target."
        case .missingKey:
            return "Orbit needs a key combination before it can press it."
        case .unsupportedKey(let key):
            return "Orbit doesn't know how to press \(key) yet."
        case .eventCreationFailed:
            return "Orbit couldn't create the desktop input event."
        }
    }
}

@MainActor
final class OrbitDesktopActuator {
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    func perform(
        _ step: OrbitDesktopActionStep,
        at globalLocation: CGPoint?
    ) async throws {
        switch step.kind {
        case .move:
            guard let globalLocation else { throw OrbitDesktopActuatorError.missingCoordinate }
            try movePointer(to: globalLocation)
        case .click:
            guard let globalLocation else { throw OrbitDesktopActuatorError.missingCoordinate }
            try click(button: .left, at: globalLocation, clickState: 1)
        case .doubleClick:
            guard let globalLocation else { throw OrbitDesktopActuatorError.missingCoordinate }
            try click(button: .left, at: globalLocation, clickState: 2)
        case .rightClick:
            guard let globalLocation else { throw OrbitDesktopActuatorError.missingCoordinate }
            try click(button: .right, at: globalLocation, clickState: 1)
        case .typeText:
            if let globalLocation {
                try click(button: .left, at: globalLocation, clickState: 1)
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            guard let text = step.text, !text.isEmpty else { throw OrbitDesktopActuatorError.missingText }
            try typeText(text)
        case .pressKey:
            guard let keyString = step.key, !keyString.isEmpty else { throw OrbitDesktopActuatorError.missingKey }
            try pressKeyCombo(keyString)
        }
    }

    private func movePointer(to globalLocation: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: globalLocation, mouseButton: .left) else {
            throw OrbitDesktopActuatorError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private func click(button: CGMouseButton, at globalLocation: CGPoint, clickState: Int64) throws {
        try movePointer(to: globalLocation)

        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .center:
            downType = .otherMouseDown
            upType = .otherMouseUp
        @unknown default:
            downType = .leftMouseDown
            upType = .leftMouseUp
        }

        guard let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: globalLocation, mouseButton: button),
              let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: globalLocation, mouseButton: button) else {
            throw OrbitDesktopActuatorError.eventCreationFailed
        }

        downEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
        upEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)

        if clickState == 2 {
            try awaitTinyDelay()
            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }
    }

    private func awaitTinyDelay() throws {
        Thread.sleep(forTimeInterval: 0.05)
    }

    private func typeText(_ text: String) throws {
        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            throw OrbitDesktopActuatorError.eventCreationFailed
        }

        let utf16 = Array(text.utf16)
        downEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        upEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    private func pressKeyCombo(_ combo: String) throws {
        let parts = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let last = parts.last else {
            throw OrbitDesktopActuatorError.missingKey
        }

        let modifiers = parts.dropLast().reduce(CGEventFlags()) { flags, token in
            flags.union(modifierFlag(for: token))
        }

        let keyCode = try keyCode(for: last)

        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
            throw OrbitDesktopActuatorError.eventCreationFailed
        }

        downEvent.flags = modifiers
        upEvent.flags = modifiers
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    private func modifierFlag(for token: String) -> CGEventFlags {
        switch token {
        case "command", "cmd":
            return .maskCommand
        case "shift":
            return .maskShift
        case "option", "alt":
            return .maskAlternate
        case "control", "ctrl":
            return .maskControl
        case "fn", "function":
            return .maskSecondaryFn
        default:
            return []
        }
    }

    private func keyCode(for token: String) throws -> CGKeyCode {
        if let single = token.unicodeScalars.first, token.count == 1 {
            switch Character(String(single).lowercased()) {
            case "a": return CGKeyCode(kVK_ANSI_A)
            case "b": return CGKeyCode(kVK_ANSI_B)
            case "c": return CGKeyCode(kVK_ANSI_C)
            case "d": return CGKeyCode(kVK_ANSI_D)
            case "e": return CGKeyCode(kVK_ANSI_E)
            case "f": return CGKeyCode(kVK_ANSI_F)
            case "g": return CGKeyCode(kVK_ANSI_G)
            case "h": return CGKeyCode(kVK_ANSI_H)
            case "i": return CGKeyCode(kVK_ANSI_I)
            case "j": return CGKeyCode(kVK_ANSI_J)
            case "k": return CGKeyCode(kVK_ANSI_K)
            case "l": return CGKeyCode(kVK_ANSI_L)
            case "m": return CGKeyCode(kVK_ANSI_M)
            case "n": return CGKeyCode(kVK_ANSI_N)
            case "o": return CGKeyCode(kVK_ANSI_O)
            case "p": return CGKeyCode(kVK_ANSI_P)
            case "q": return CGKeyCode(kVK_ANSI_Q)
            case "r": return CGKeyCode(kVK_ANSI_R)
            case "s": return CGKeyCode(kVK_ANSI_S)
            case "t": return CGKeyCode(kVK_ANSI_T)
            case "u": return CGKeyCode(kVK_ANSI_U)
            case "v": return CGKeyCode(kVK_ANSI_V)
            case "w": return CGKeyCode(kVK_ANSI_W)
            case "x": return CGKeyCode(kVK_ANSI_X)
            case "y": return CGKeyCode(kVK_ANSI_Y)
            case "z": return CGKeyCode(kVK_ANSI_Z)
            case "0": return CGKeyCode(kVK_ANSI_0)
            case "1": return CGKeyCode(kVK_ANSI_1)
            case "2": return CGKeyCode(kVK_ANSI_2)
            case "3": return CGKeyCode(kVK_ANSI_3)
            case "4": return CGKeyCode(kVK_ANSI_4)
            case "5": return CGKeyCode(kVK_ANSI_5)
            case "6": return CGKeyCode(kVK_ANSI_6)
            case "7": return CGKeyCode(kVK_ANSI_7)
            case "8": return CGKeyCode(kVK_ANSI_8)
            case "9": return CGKeyCode(kVK_ANSI_9)
            default:
                break
            }
        }

        switch token {
        case "return", "enter":
            return CGKeyCode(kVK_Return)
        case "tab":
            return CGKeyCode(kVK_Tab)
        case "space":
            return CGKeyCode(kVK_Space)
        case "escape", "esc":
            return CGKeyCode(kVK_Escape)
        case "delete", "backspace":
            return CGKeyCode(kVK_Delete)
        case "forwarddelete":
            return CGKeyCode(kVK_ForwardDelete)
        case "left":
            return CGKeyCode(kVK_LeftArrow)
        case "right":
            return CGKeyCode(kVK_RightArrow)
        case "up":
            return CGKeyCode(kVK_UpArrow)
        case "down":
            return CGKeyCode(kVK_DownArrow)
        default:
            throw OrbitDesktopActuatorError.unsupportedKey(token)
        }
    }
}
