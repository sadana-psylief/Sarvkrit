import AudioToolbox
import CoreAudio
import Foundation
import os

/// Attenuates one app's audio.
///
/// The only public, driver-free way to do this. A `CATapDescription` naming the process, created
/// with `AudioHardwareCreateProcessTap` in `.mutedWhenTapped` mode so the app's audio stops going
/// straight to the speakers, wrapped in a **private** aggregate device whose IOProc reads the tap
/// and writes it back out scaled by the level.
///
/// Everything else that does this — SoundSource, Background Music — installs a HAL plugin, which
/// means an admin installer and a bundle in `/Library/Audio/Plug-Ins/HAL/`. That is a different
/// kind of software from a menu bar app, and not one this should become.
///
/// **Two things to know when reading this:**
///
/// - The render callback is real-time audio. No allocation, no locks, no logging — the level is read
///   through an atomic-ish plain float precisely so the callback never waits for anything.
///   `SoftClip` is a free function over `Float` for the same reason.
/// - Permission failure is **silent**. Every call here returns `noErr` when system-audio recording
///   is denied; the only evidence is that the buffers are all zeros. `silentRenderCount` exists so
///   the feature can notice and say so, rather than appearing to work while doing nothing.
final class AudioProcessTap {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Mixer")

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    private let processObjectID: AudioObjectID
    let bundleID: String

    /// Read on the audio thread every render. Deliberately a plain stored property: a lock here
    /// would be a priority inversion waiting to happen.
    private var level: Float = 1

    /// How many consecutive renders produced nothing but silence, which is what a denied permission
    /// looks like. Written on the audio thread, read on main — approximate by design, since it only
    /// ever drives a piece of UI copy.
    private(set) var silentRenderCount: Int = 0

    init?(processObjectID: AudioObjectID, bundleID: String, level: Float) {
        self.processObjectID = processObjectID
        self.bundleID = bundleID
        self.level = level
        guard start() else { return nil }
    }

    /// Clamped to `MixerLevels.range`, which now runs past unity — see there for why the ceiling
    /// is 2 and not higher.
    func setLevel(_ level: Float) {
        self.level = min(MixerLevels.maximum, max(MixerLevels.minimum, level))
    }

    // MARK: - Setting up

    private func start() -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "Sarvkrit \(bundleID)"
        description.uuid = UUID()
        // Private: this tap is ours, and should not appear in other apps' device lists.
        description.isPrivate = true
        // The whole mechanism. Unmuted, the app's audio would reach the speakers *and* the tap, and
        // we would only be adding a second, quieter copy on top.
        description.muteBehavior = .mutedWhenTapped

        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
            log.error("could not create a tap for \(self.bundleID, privacy: .public)")
            return false
        }

        guard let outputUID = defaultOutputUID() else {
            destroy()
            return false
        }
        let tapUID = description.uuid.uuidString

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sarvkrit Mixer \(bundleID)",
            kAudioAggregateDeviceUIDKey: "ai.psylief.sarvkrit.mixer.\(bundleID)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private, so it never shows up as something the user could select.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
        ]

        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID
        ) == noErr, aggregateID != 0 else {
            log.error("could not create the mixer device for \(self.bundleID, privacy: .public)")
            destroy()
            return false
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, nil
        ) { [weak self] _, inputData, _, outputData, _ in
            self?.render(input: inputData, output: outputData)
        }
        guard status == noErr, ioProcID != nil else {
            destroy()
            return false
        }

        // This is what triggers the system-audio permission prompt — not creating the tap.
        guard AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            destroy()
            return false
        }
        return true
    }

    /// Real-time. Nothing here may allocate, lock or log.
    private func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let gain = level
        var sawAnything = false

        for index in 0..<min(inputBuffers.count, outputBuffers.count) {
            let source = inputBuffers[index]
            let destination = outputBuffers[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            let frames = Int(min(source.mDataByteSize, destination.mDataByteSize))
                / MemoryLayout<Float>.size
            let from = sourceData.assumingMemoryBound(to: Float.self)
            let to = destinationData.assumingMemoryBound(to: Float.self)

            for frame in 0..<frames {
                let sample = from[frame]
                if sample != 0 { sawAnything = true }
                // `SoftClip.apply` is plain multiplication at or below unity gain, so nothing
                // changes for an app that has only ever been turned down. Above it, the curve is
                // what stops a boosted signal from clipping into broadband distortion on exactly
                // the transients you notice.
                to[frame] = SoftClip.apply(sample, gain: gain)
            }
        }

        // Denial looks exactly like this: calls succeed, buffers are empty. Counting lets the
        // feature say so instead of pretending to work.
        silentRenderCount = sawAnything ? 0 : silentRenderCount &+ 1
    }

    // MARK: - Tearing down

    func destroy() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    /// A tap left running holds the app's audio muted. Leaking one would leave a silent app with no
    /// visible cause — far worse than the usual cost of a leak.
    deinit {
        destroy()
    }

    private func defaultOutputUID() -> String? {
        guard let device = AudioSystem.defaultDevice(.output) else { return nil }
        return AudioSystem.devices().first { $0.id == device }?.uid
    }
}
