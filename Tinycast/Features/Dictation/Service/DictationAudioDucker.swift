import CoreAudio
import Foundation
import OSLog

@MainActor
final class DictationAudioDucker {
    struct Output {
        let deviceUID: String
        let read: () throws -> Float
        let write: (Float) throws -> Void
    }

    private struct Snapshot {
        let output: Output
        var volume: DictationVolumeSnapshot
    }

    private static let logger = Logger(subsystem: "com.tinycast", category: "DictationVolume")
    private let fileURL: URL
    private let defaultOutput: () throws -> Output?
    private let resolveOutput: (String) throws -> Output?
    private var snapshot: Snapshot?
    private var transition: Task<Void, Never>?

    init(
        fileURL: URL = AppPaths.applicationSupport().appending(path: "dictation-volume.json"),
        defaultOutput: @escaping () throws -> Output? = {
            guard #available(macOS 26, *) else { return try SequoiaAudioOutput.defaultOutput() }
            return try AudioHardwareSystem.shared.defaultOutputDevice.flatMap {
                try DictationAudioDucker.output(for: $0)
            }
        },
        resolveOutput: @escaping (String) throws -> Output? = { uid in
            guard #available(macOS 26, *) else { return try SequoiaAudioOutput.output(forUID: uid) }
            return try AudioHardwareSystem.shared.device(forUID: uid).flatMap {
                try DictationAudioDucker.output(for: $0)
            }
        }
    ) {
        self.fileURL = fileURL
        self.defaultOutput = defaultOutput
        self.resolveOutput = resolveOutput
    }

    isolated deinit { transition?.cancel() }

    func recover() {
        schedule { _ = try await $0.recoverSavedVolume() }
    }

    func begin() {
        schedule { ducker in
            if ducker.snapshot == nil {
                guard try await ducker.recoverSavedVolume(),
                    let output = try ducker.defaultOutput()
                else { return }
                let original = try output.read()
                let volume = DictationVolumeSnapshot(
                    deviceUID: output.deviceUID, original: original, lastSet: original)
                guard volume.isValid, original > 0 else { return }
                ducker.snapshot = Snapshot(output: output, volume: volume)
            }
            guard let snapshot = ducker.snapshot else { return }
            try await ducker.fade(to: snapshot.volume.original * 0.1, release: false)
        }
    }

    func end() {
        guard snapshot != nil || transition != nil else { return }
        schedule { ducker in
            guard let snapshot = ducker.snapshot else { return }
            try await ducker.fade(to: snapshot.volume.original, release: true)
        }
    }

    func restoreImmediately() {
        transition?.cancel()
        if let snapshot, let current = try? snapshot.output.read(), snapshot.volume.matches(current) {
            do { try snapshot.output.write(snapshot.volume.original) } catch {
                Self.logger.error("Couldn't restore dictation volume: \(error.localizedDescription)")
            }
        }
        snapshot = nil
        recover()
    }

    func waitForTransition() async {
        while let transition { await transition.value }
    }

    private func schedule(_ operation: @escaping @MainActor (DictationAudioDucker) async throws -> Void) {
        let previous = transition
        previous?.cancel()
        transition = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            do { try await operation(self) } catch is CancellationError {
            } catch {
                Self.logger.error("Couldn't update dictation volume: \(error.localizedDescription)")
                if snapshot != nil { restoreImmediately() }
            }
            if !Task.isCancelled { transition = nil }
        }
    }

    private func fade(to target: Float, release: Bool) async throws {
        guard let snapshot else { return }
        let start = try snapshot.output.read()
        guard snapshot.volume.matches(start) else {
            try await clear()
            return
        }
        for step in 1...16 {
            try Task.checkCancellation()
            guard let snapshot = self.snapshot else { return }
            let volume = start + (target - start) * Float(step) / 16
            var saved = snapshot.volume
            saved.previous = saved.lastSet
            saved.lastSet = volume
            // A crash between persistence and the hardware write must recover either volume.
            try await persist(saved)
            try Task.checkCancellation()
            guard snapshot.volume.matches(try snapshot.output.read()) else {
                try await clear()
                return
            }
            try snapshot.output.write(volume)
            self.snapshot?.volume.lastSet = try snapshot.output.read()
            self.snapshot?.volume.previous = nil
            if step < 16 { try await Task.sleep(for: .milliseconds(30)) }
        }
        if release { try await clear() }
    }

    private func recoverSavedVolume() async throws -> Bool {
        let fileURL = fileURL
        let volume = try await Task.detached(priority: .utility) { () -> DictationVolumeSnapshot? in
            do {
                return try JSONDecoder().decode(DictationVolumeSnapshot.self, from: Data(contentsOf: fileURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }.value
        try Task.checkCancellation()
        guard let volume else { return true }
        guard volume.isValid else { try await persist(nil); return true }
        guard let output = try resolveOutput(volume.deviceUID) else { return false }
        let current = try output.read()
        if volume.matches(current), current != volume.original { try output.write(volume.original) }
        try await persist(nil)
        return true
    }

    private func clear() async throws {
        snapshot = nil
        try await persist(nil)
    }

    private func persist(_ volume: DictationVolumeSnapshot?) async throws {
        let fileURL = fileURL
        try await Task.detached(priority: .utility) {
            if let volume {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try JSONEncoder().encode(volume).write(to: fileURL, options: .atomic)
            } else {
                do { try FileManager.default.removeItem(at: fileURL) } catch let error as CocoaError
                    where error.code == .fileNoSuchFile
                {}
            }
        }.value
    }

    @available(macOS 26, *)
    private static func output(for device: AudioHardwareDevice) throws -> Output? {
        guard let control = try device.controls.first(where: isMainOutputVolume) else { return nil }
        return Output(
            deviceUID: try device.uid,
            read: { try control.volumeScalarValue }, write: { try control.setVolumeScalarValue($0) })
    }

    @available(macOS 26, *)
    private static func isMainOutputVolume(_ control: AudioHardwareControl) -> Bool {
        guard (try? control.classID) == kAudioVolumeControlClassID else { return false }
        func value(for selector: AudioObjectPropertySelector) -> UInt32? {
            let address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard let data = try? control.propertyData(address: address, qualifier: nil),
                data.count == MemoryLayout<UInt32>.size
            else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        return value(for: kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput
            && value(for: kAudioControlPropertyElement) == kAudioObjectPropertyElementMain
    }
}

/// Sequoia has no `AudioHardwareSystem`, so it reads the same HAL properties that API wraps.
private enum SequoiaAudioOutput {
    static func defaultOutput() throws -> DictationAudioDucker.Output? {
        let device = try value(
            of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown))
        return try output(for: device)
    }

    static func output(forUID uid: String) throws -> DictationAudioDucker.Output? {
        var address = mainAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try withUnsafeMutablePointer(to: &qualifier) { qualifier in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device))
        }
        return try output(for: device)
    }

    private static func output(for device: AudioObjectID) throws -> DictationAudioDucker.Output? {
        guard device != AudioObjectID(kAudioObjectUnknown),
            let control = try controls(of: device).first(where: isMainOutputVolume)
        else { return nil }
        return DictationAudioDucker.Output(
            deviceUID: try uid(of: device),
            read: {
                try Self.value(of: control, kAudioLevelControlPropertyScalarValue, initial: Float32(0))
            },
            write: { volume in
                var address = Self.mainAddress(kAudioLevelControlPropertyScalarValue)
                var volume = volume
                try Self.check(
                    AudioObjectSetPropertyData(
                        control, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume))
            })
    }

    private static func isMainOutputVolume(_ control: AudioObjectID) -> Bool {
        (try? value(of: control, kAudioObjectPropertyClass, initial: AudioClassID(0)))
            == kAudioVolumeControlClassID
            && (try? value(of: control, kAudioControlPropertyScope, initial: UInt32(0)))
                == kAudioObjectPropertyScopeOutput
            && (try? value(of: control, kAudioControlPropertyElement, initial: UInt32(0)))
                == kAudioObjectPropertyElementMain
    }

    private static func controls(of device: AudioObjectID) throws -> [AudioObjectID] {
        var address = mainAddress(kAudioObjectPropertyControlList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size))
        let stride = MemoryLayout<AudioObjectID>.stride
        var controls = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / stride)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &controls))
        return Array(controls.prefix(Int(size) / stride))
    }

    private static func uid(of device: AudioObjectID) throws -> String {
        var address = mainAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &uid) { uid in
            try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, uid))
        }
        guard let uid else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadDeviceError))
        }
        return uid.takeRetainedValue() as String
    }

    private static func value<Value>(
        of object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: Value
    ) throws -> Value {
        var address = mainAddress(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try withUnsafeMutablePointer(to: &value) { value in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value))
        }
        return value
    }

    private static func mainAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
