import Foundation

/// Настройки приложения, хранятся в UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    enum ShakeMode: String, CaseIterable {
        case whileDragging, always, off

        var title: String {
            switch self {
            case .always: return "Всегда, даже без файла"
            case .whileDragging: return "Только при перетаскивании"
            case .off: return "Выключено"
            }
        }
    }

    enum Sensitivity: String, CaseIterable {
        case low, normal, high

        var title: String {
            switch self {
            case .low: return "Низкая"
            case .normal: return "Обычная"
            case .high: return "Высокая"
            }
        }

        /// Сколько смен направления нужно и за какое время.
        var reversals: Int { self == .high ? 3 : 4 }
        var window: TimeInterval { self == .low ? 0.55 : 0.75 }
        var minDistance: CGFloat {
            switch self {
            case .low: return 70
            case .normal: return 45
            case .high: return 30
            }
        }
    }

    static var shakeMode: ShakeMode {
        get { ShakeMode(rawValue: d.string(forKey: "shakeMode") ?? "") ?? .whileDragging }
        set { d.set(newValue.rawValue, forKey: "shakeMode") }
    }

    static var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .normal }
        set { d.set(newValue.rawValue, forKey: "sensitivity") }
    }

    /// Убирать объекты с полки, когда их перетащили наружу.
    static var removeAfterDrag: Bool {
        get { d.object(forKey: "removeAfterDrag") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeAfterDrag") }
    }

    /// Звук при появлении полки.
    static var playSound: Bool {
        get { d.object(forKey: "playSound") as? Bool ?? false }
        set { d.set(newValue, forKey: "playSound") }
    }
}
