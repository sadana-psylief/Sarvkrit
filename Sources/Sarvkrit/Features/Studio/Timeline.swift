import Foundation

/// One stretch of the recording, as it appears in the finished video.
///
/// **Trimming never removes anything.** `sourceStart` and `sourceEnd` are a window onto the
/// recording, which is why un-trimming is free, why the trim badge can honestly say how much is
/// hidden, and why clicking that badge can put the material back. The alternative — cutting the
/// file — makes every edit final and the badge a lie.
struct Clip: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Seconds into the recording. Both ends are in *source* time, always.
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var speed: Double = 1
    /// The microphone track.
    var volume: Double = 1
    /// Kept apart from `volume` because "mute the video I was demonstrating but keep my narration"
    /// is the common case, and one number cannot say it.
    var systemAudioVolume: Double = 1
    var isMuted = false
    /// For a stretch where the pointer is parked over the thing being discussed.
    var hidesCursor = false
    /// For a stretch where precision beats grace — walking down a menu, dragging a handle. The
    /// interpolation that makes a cursor look weightless also makes it appear to hover between
    /// items it never touched.
    var disablesCursorSmoothing = false
    /// Seconds of dip to black at this clip's *start*, half either side of the cut.
    ///
    /// Belongs to the clip that starts at the cut, the same convention
    /// `sourceTime(forOutput:)` uses for the boundary. Ignored on the first clip, which has no cut
    /// before it — a fade in is the setting for that.
    var dipToBlack: TimeInterval = 0
    /// Extra output seconds during which the clip's last frame is held.
    ///
    /// **A freeze frame, as one field rather than a new kind of clip.** It composes with speed and
    /// trimming — the moving part shortens with speed, the hold does not — and it needs no new
    /// mapping: the source time simply stops advancing.
    var hold: TimeInterval = 0

    static let speedRange: ClosedRange<Double> = 0.25...4

    /// Below this a clip cannot be grabbed with a mouse and shows nothing anybody can see, so the
    /// operations that would create one refuse instead. Measured in *output* seconds, because that
    /// is what the user is looking at: 100 ms of source at 4× is 25 ms on screen.
    static let minimumOutputDuration: TimeInterval = 0.1

    /// Hand-written for the same reason `StudioProject`'s and `RecordingManifest`'s are: **a
    /// missing key takes a default and never throws.**
    ///
    /// A synthesized decoder throws on a missing key even when the property has a default — a
    /// default is not the same as optional — so every field added to this struct was a chance to
    /// make every previously saved project unreadable. And `StudioDocumentModel` treats an
    /// unreadable project as "no project", so the failure mode was not an error message: it was
    /// somebody's edits quietly disappearing. Caught by a test before it shipped, once.
    private enum Key: String, CodingKey {
        case id, sourceStart, sourceEnd, speed, volume, systemAudioVolume
        case isMuted, hidesCursor, disablesCursorSmoothing, hold, dipToBlack
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func read<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        id = read(.id, UUID())
        sourceStart = read(.sourceStart, 0)
        sourceEnd = read(.sourceEnd, 0)
        speed = read(.speed, 1)
        volume = read(.volume, 1)
        systemAudioVolume = read(.systemAudioVolume, 1)
        isMuted = read(.isMuted, false)
        hidesCursor = read(.hidesCursor, false)
        disablesCursorSmoothing = read(.disablesCursorSmoothing, false)
        hold = read(.hold, 0)
        dipToBlack = read(.dipToBlack, 0)
    }

    /// Spelled out because the hand-written decoder above suppresses the memberwise one.
    init(id: UUID = UUID(), sourceStart: TimeInterval, sourceEnd: TimeInterval,
         speed: Double = 1, volume: Double = 1, systemAudioVolume: Double = 1,
         isMuted: Bool = false, hidesCursor: Bool = false,
         disablesCursorSmoothing: Bool = false, hold: TimeInterval = 0,
         dipToBlack: TimeInterval = 0) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
        self.volume = volume
        self.systemAudioVolume = systemAudioVolume
        self.isMuted = isMuted
        self.hidesCursor = hidesCursor
        self.disablesCursorSmoothing = disablesCursorSmoothing
        self.hold = hold
        self.dipToBlack = dipToBlack
    }

    var sourceDuration: TimeInterval { max(0, sourceEnd - sourceStart) }

    /// How long the moving part occupies in the finished video, before any held frame.
    var movingOutputDuration: TimeInterval { sourceDuration / speed }

    /// How long this clip occupies in the finished video, including a held last frame.
    var outputDuration: TimeInterval { movingOutputDuration + max(0, hold) }
}

/// The edit: a list of clips, and the arithmetic that maps between the finished video and the
/// recording it was cut from.
///
/// **Every track in the studio is stored in source time** — zooms, camera layouts, masks,
/// keystrokes, captions — and resolved for rendering through `sourceTime(forOutput:)`. That is
/// what makes trimming the first two seconds leave the zooms attached to the moments they were
/// built for rather than sliding them all two seconds early.
///
/// Pure, and deliberately so: this is the one place a speed change becomes correct or subtly
/// wrong, and a sped-up section that desynchronises everything but the video is the kind of defect
/// that reads as "the app is broken" rather than as an off-by-one.
struct Timeline: Codable, Equatable {
    var clips: [Clip]

    init(clips: [Clip]) {
        self.clips = clips
    }

    var duration: TimeInterval {
        clips.reduce(0) { $0 + $1.outputDuration }
    }

    // MARK: - Mapping

    /// The recording moment shown at `output` seconds into the finished video.
    ///
    /// A clip owns the half-open interval `[start, end)`. The boundary therefore belongs to the
    /// clip that *starts* there rather than the one that ended, which is what stops a cut showing
    /// one frame of the outgoing clip; and asking for exactly the duration returns nil, because
    /// there is no frame left to show.
    func sourceTime(forOutput output: TimeInterval) -> (clip: Clip, sourceTime: TimeInterval)? {
        guard output >= 0 else { return nil }
        var elapsed: TimeInterval = 0
        for clip in clips {
            let next = elapsed + clip.outputDuration
            if output < next {
                let into = output - elapsed
                // Past the moving part, the clip is holding its last frame. A hair inside the end
                // rather than exactly on it, because a clip owns `[start, end)` and every other
                // track resolves against that half-open range.
                guard into < clip.movingOutputDuration else {
                    return (clip, max(clip.sourceStart, clip.sourceEnd - 0.0001))
                }
                return (clip, clip.sourceStart + into * clip.speed)
            }
            elapsed = next
        }
        return nil
    }

    /// The inverse: where a moment of the recording ended up, or nil if it was cut out.
    ///
    /// Nil is a useful answer rather than a failure — it is what lets the renderer skip a zoom
    /// whose moment the user deleted, instead of drawing it at the wrong time.
    func outputTime(forSource source: TimeInterval) -> TimeInterval? {
        var elapsed: TimeInterval = 0
        for clip in clips {
            if source >= clip.sourceStart && source < clip.sourceEnd {
                return elapsed + (source - clip.sourceStart) / clip.speed
            }
            elapsed += clip.outputDuration
        }
        return nil
    }

    // MARK: - Edits

    /// Cuts the clip under `output` in two. `output` is in output time — the playhead's own units —
    /// so a sped-up clip splits at the frame the user is actually looking at.
    func split(at output: TimeInterval) -> Timeline {
        guard let (clip, source) = sourceTime(forOutput: output),
              let index = clips.firstIndex(where: { $0.id == clip.id }) else { return self }

        var left = clip
        left.sourceEnd = source
        var right = clip
        right.id = UUID()
        right.sourceStart = source

        // A split that would leave a sliver nobody can grab is refused rather than performed. The
        // user's intent was a cut, and a cut they cannot see or select is worse than none.
        guard left.outputDuration >= Clip.minimumOutputDuration,
              right.outputDuration >= Clip.minimumOutputDuration else { return self }

        var updated = self
        updated.clips.replaceSubrange(index...index, with: [left, right])
        return updated
    }

    /// Removes a clip and closes the gap. The clips after it slide left; nothing is left blank.
    ///
    /// The last clip cannot go: an empty timeline has no duration, no playhead and no clip to
    /// drag, so there would be no way to edit back out of it.
    func delete(id: Clip.ID) -> Timeline {
        guard clips.count > 1, clips.contains(where: { $0.id == id }) else { return self }
        var updated = self
        updated.clips.removeAll { $0.id == id }
        return updated
    }

    /// Moves one or both edges of a clip's window onto the recording. Nil leaves that edge alone.
    func trim(id: Clip.ID, start: TimeInterval?, end: TimeInterval?) -> Timeline {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return self }
        var clip = clips[index]
        if let start { clip.sourceStart = start }
        if let end { clip.sourceEnd = end }
        guard clip.sourceEnd > clip.sourceStart,
              clip.outputDuration >= Clip.minimumOutputDuration else { return self }

        var updated = self
        updated.clips[index] = clip
        return updated
    }

    /// Moves a clip to a different place in the running order.
    ///
    /// **Correct by construction, which is why there is so little here.** `sourceTime(forOutput:)`
    /// walks the clips in array order, and every other track — zooms, masks, camera layouts,
    /// captions — is stored in *source* time and resolved through that mapping. So a clip carries
    /// its material with it and whatever was attached to that material arrives with it. There was
    /// simply never a method to do it.
    ///
    /// A move that changes nothing is refused, so it costs no undo step.
    func move(from index: Int, to destination: Int) -> Timeline {
        guard clips.indices.contains(index), clips.indices.contains(destination),
              index != destination else { return self }
        var updated = self
        let clip = updated.clips.remove(at: index)
        updated.clips.insert(clip, at: destination)
        return updated
    }

    /// A second copy of a clip, immediately after it.
    ///
    /// The copy gets a new identity, or selection and every per-clip edit would address both at
    /// once. Note that both copies show the same material, so anything attached to that material
    /// renders in both — which is usually what somebody duplicating a clip wants.
    func duplicate(id: Clip.ID) -> Timeline {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return self }
        var copy = clips[index]
        copy.id = UUID()
        var updated = self
        updated.clips.insert(copy, at: index + 1)
        return updated
    }

    /// Moves the cut between a clip and its neighbour without moving where that cut falls in the
    /// finished video: one side gains the material the other gives up.
    ///
    /// The adjustment a cut most often needs — "start the next shot a little earlier" — without
    /// disturbing anything downstream of it.
    func roll(after id: Clip.ID, by seconds: TimeInterval) -> Timeline {
        guard let index = clips.firstIndex(where: { $0.id == id }),
              clips.indices.contains(index + 1), seconds != 0 else { return self }

        var left = clips[index]
        var right = clips[index + 1]
        left.sourceEnd += seconds
        right.sourceStart += seconds

        guard left.sourceEnd > left.sourceStart, right.sourceEnd > right.sourceStart,
              left.outputDuration >= Clip.minimumOutputDuration,
              right.outputDuration >= Clip.minimumOutputDuration else { return self }

        var updated = self
        updated.clips[index] = left
        updated.clips[index + 1] = right
        return updated
    }

    func setSpeed(id: Clip.ID, _ speed: Double) -> Timeline {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return self }
        var updated = self
        updated.clips[index].speed = min(max(speed, Clip.speedRange.lowerBound),
                                         Clip.speedRange.upperBound)
        return updated
    }

    func clip(withID id: Clip.ID) -> Clip? {
        clips.first { $0.id == id }
    }
}
