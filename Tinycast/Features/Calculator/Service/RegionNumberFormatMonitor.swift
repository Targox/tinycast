import Foundation

/// Follows Language & Region's number format, so a change there applies without a relaunch.
@MainActor
@Observable
final class RegionNumberFormatMonitor {
    private(set) var system = RegionNumberFormatMonitor.read()
    @ObservationIgnored private var token: NotificationToken?

    init() {
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.system = Self.read() }
        }
        token = NotificationToken(observer, center: center)
    }

    func format(for style: CalcNumberStyle) -> CalcNumberFormat {
        style == .system ? system : .english
    }

    /// Separators the parser can't take, such as the Arabic `٫`, fall back to English.
    private static func read() -> CalcNumberFormat {
        let locale = Locale.autoupdatingCurrent
        return CalcNumberFormat(
            decimalSeparator: locale.decimalSeparator ?? ".", groupingSeparator: locale.groupingSeparator)
            ?? .english
    }
}
