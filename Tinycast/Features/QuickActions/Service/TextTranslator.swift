import AppKit
import NaturalLanguage
import Synchronization
import SwiftUI
import Translation

/// `TranslationError` is macOS 26.4 against a 15.0 floor, so failures stay plain `Error` here.
enum TextTranslator {
    enum Failure: LocalizedError, Equatable {
        case undetectableSource
        case unsupported
        case notInstalled(language: String)
        case failed

        var errorDescription: String? {
            switch self {
            case .undetectableSource:
                return "The language of the selected text could not be identified."
            case .unsupported:
                return "Apple's translator does not support this language pair."
            case .notInstalled(let language):
                return "\(language) needs to be downloaded before it can be used."
            case .failed:
                return "The text could not be translated."
            }
        }
    }

    /// `TranslationSession(installedSource:)` needs a language; availability reports only a status.
    static func sourceLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            return nil
        }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Installed pairs only: a missing language is downloaded in System Settings, never from here.
    static func translate(_ text: String, to target: Locale.Language) async throws -> String {
        guard let source = sourceLanguage(of: text) else { throw Failure.undetectableSource }
        guard !source.isEquivalent(to: target) else { return text }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            throw Failure.notInstalled(language: displayName(of: target))
        case .unsupported:
            throw Failure.unsupported
        @unknown default:
            throw Failure.unsupported
        }
        do {
            guard #available(macOS 26, *) else {
                return try await SequoiaTranslator.translate(text, from: source, to: target)
            }
            let session = TranslationSession(installedSource: source, target: target)
            return try await session.translate(text).targetText
        } catch {
            throw Failure.failed
        }
    }

    /// Minimal, not maximal: the maximal form would spell `es` "Spanish (Latin, Spain)" in a menu.
    static func displayName(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    /// The framework's own list, so the picker cannot offer a pair that only fails at press time.
    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
            .sorted { displayName(of: $0) < displayName(of: $1) }
    }
}

/// Sequoia hands out a `TranslationSession` only through SwiftUI, so an unseen view asks for one.
private enum SequoiaTranslator {
    @MainActor
    static func translate(
        _ text: String, from source: Locale.Language, to target: Locale.Language
    ) async throws -> String {
        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let pending = PendingTranslation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.store(continuation)
                let configuration = TranslationSession.Configuration(source: source, target: target)
                let probe = Color.clear.translationTask(configuration) { session in
                    do {
                        let translated = try await session.translate(text).targetText
                        pending.resume(with: .success(translated))
                    } catch {
                        pending.resume(with: .failure(error))
                    }
                }
                panel.contentView = NSHostingView(rootView: probe)
                panel.orderFrontRegardless()
            }
        } onCancel: {
            pending.cancel()
        }
    }
}

/// Resumed once, by whichever lands first: the session's answer or the caller's cancellation.
private final class PendingTranslation: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, any Error>?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func store(_ continuation: CheckedContinuation<String, any Error>) {
        let cancelled = state.withLock { state in
            state.continuation = state.isCancelled ? nil : continuation
            return state.isCancelled
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func resume(with result: Result<String, any Error>) {
        state.withLock { $0.continuation.take() }?.resume(with: result)
    }

    func cancel() {
        let continuation = state.withLock { state in
            state.isCancelled = true
            return state.continuation.take()
        }
        continuation?.resume(throwing: CancellationError())
    }
}
