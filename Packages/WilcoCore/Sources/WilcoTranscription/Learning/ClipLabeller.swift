import Foundation
import WilcoCore

/// Labels a session's kept clips after a show: each voter transcribes each
/// clip and their word agreement is recorded, then each channel's clips are
/// grouped by voice with two speaker-grouping models. `labels.json` is saved
/// after every clip, so labelling can stop when capture starts and carry on
/// later from where it stopped.
public struct ClipLabeller: Sendable {
    /// In preference order.
    private let voters: [any ClipVoter]
    private let diarizers: [any ClipDiarizer]

    static let sampleRate = 16_000
    /// Clips a channel needs before its voices are grouped.
    static let minimumVoiceClips = 3

    public init(voters: [any ClipVoter], diarizers: [any ClipDiarizer]) {
        self.voters = voters
        self.diarizers = diarizers
    }

    public var voterVersions: [String: String] {
        Dictionary(voters.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
    }

    /// Labels one session's clips, saving labels.json after each clip. Clips already
    /// labelled with the same voters (and any with `checked`) are kept. Throws
    /// CancellationError between clips when cancelled; what's done is saved.
    public func label(transcript: URL, show: ShowDocument?, progress: @Sendable (Int, Int) -> Void) async throws {
        let folder = ClipsFolder.url(forTranscript: transcript)
        guard let manifest = ClipsFolder.loadManifest(in: folder) else { return }
        let versions = voterVersions
        let existing = ClipsFolder.loadLabels(in: folder)
        let sameVoters = existing?.voters == versions

        // Kept from earlier runs: everything when the voters are the same,
        // else only clips someone has checked. Clips no longer in the
        // manifest are dropped.
        var kept: [UUID: ClipLabel] = [:]
        for label in existing?.clips ?? [] where sameVoters || label.checked != nil {
            kept[label.clip] = label
        }
        let records = manifest.clips.filter {
            FileManager.default.fileExists(atPath: ClipsFolder.audioURL(for: $0.id, in: folder).path)
        }
        let toLabel = records.filter { kept[$0.id] == nil }
        let manifestIDs = Set(manifest.clips.map(\.id))
        let nothingDropped = (existing?.clips ?? []).allSatisfy { manifestIDs.contains($0.clip) }
        if let existing, existing.finished, sameVoters, toLabel.isEmpty, nothingDropped {
            progress(records.count, records.count)
            return
        }

        var labels = ClipLabels(voters: versions)
        func ordered() -> [ClipLabel] { manifest.clips.compactMap { kept[$0.id] } }
        func save() throws {
            labels.clips = ordered()
            try ClipsFolder.save(labels, in: folder)
        }
        try save()

        var done = records.count - toLabel.count
        let channels = Dictionary((show?.channels ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in toLabel {
            try await stopIfCancelled(save)
            if let samples = Self.samples(of: record, in: folder) {
                let channel = channels[record.channel]
                let candidates = await transcribe(
                    samples,
                    vocabulary: show?.vocabulary(for: record.channel) ?? [],
                    localeIdentifier: channel?.localeIdentifier ?? "en-US",
                    sittingOut: ClipAgreement.sittingOut(engine: record.engine, whisperModel: record.whisperModel)
                )
                // A voter stopped part-way may have failed only because of the
                // cancel, so the clip is left for the next run.
                try await stopIfCancelled(save)
                let (verdict, text) = ClipAgreement.words(
                    candidates: candidates, voters: voters.map(\.id),
                    sittingOut: ClipAgreement.sittingOut(engine: record.engine, whisperModel: record.whisperModel)
                )
                kept[record.id] = ClipLabel(clip: record.id, words: verdict, text: text, candidates: candidates)
                try save()
            }
            done += 1
            progress(done, records.count)
        }

        try await stopIfCancelled(save)
        let voices: Voices
        do {
            voices = try await labelVoices(records.filter { kept[$0.id] != nil }, in: folder)
        } catch {
            // The voice pass only throws when cancelled.
            try save()
            throw CancellationError()
        }
        for (id, voice) in voices.byClip {
            kept[id]?.voice = voice.verdict
            kept[id]?.speaker = voice.speaker
        }
        labels.voiceError = voices.error
        try await stopIfCancelled(save)
        labels.finished = true
        try save()
    }

    private func stopIfCancelled(_ save: () throws -> Void) async throws {
        guard Task.isCancelled else { return }
        try save()
        throw CancellationError()
    }

    /// Each voter's text, leaving out voters that sit out or fail.
    private func transcribe(
        _ samples: [Float], vocabulary: [String], localeIdentifier: String, sittingOut: Set<String>
    ) async -> [String: String] {
        var candidates: [String: String] = [:]
        for voter in voters where !sittingOut.contains(voter.id) && candidates[voter.id] == nil {
            // Once cancelled the clip is thrown away, so the rest needn't run.
            if Task.isCancelled { break }
            if let text = try? await voter.transcribe(samples, vocabulary: vocabulary, localeIdentifier: localeIdentifier) {
                candidates[voter.id] = text
            }
        }
        return candidates
    }

    /// Each labelled clip's voice and speaker, and the first speaker-grouping failure.
    struct Voices {
        var byClip: [UUID: (verdict: VoiceVerdict?, speaker: Int?)] = [:]
        var error: String?
    }

    /// Groups each channel's clips by voice when exactly two speaker-grouping
    /// models are installed and the channel has enough clips; other channels'
    /// clips get no voice, as do those of a channel where a model fails (the
    /// first failure is kept). Channels run one at a time, since a model can
    /// hold a thread for seconds. Throws `CancellationError` when cancelled,
    /// including when a model fails because of the cancel.
    private func labelVoices(_ records: [ClipRecord], in folder: URL) async throws -> Voices {
        var voices = Voices()
        for record in records { voices.byClip[record.id] = (nil, nil) }
        let installed = diarizers.filter { $0.isInstalled() }
        guard installed.count == 2 else { return voices }

        var channelOrder: [UUID] = []
        var byChannel: [UUID: [ClipRecord]] = [:]
        for record in records {
            if byChannel[record.channel] == nil { channelOrder.append(record.channel) }
            byChannel[record.channel, default: []].append(record)
        }
        for channel in channelOrder {
            try Task.checkCancellation()
            var clips: [ClipRecord] = []
            var audio: [[Float]] = []
            for record in byChannel[channel] ?? [] {
                guard let samples = Self.samples(of: record, in: folder) else { continue }
                clips.append(record)
                audio.append(samples)
            }
            guard clips.count >= Self.minimumVoiceClips else { continue }

            let gap = 1.0
            let ranges = VoiceAgreement.layout(
                durations: audio.map { Double($0.count) / Double(Self.sampleRate) }, gap: gap
            )
            let silence = [Float](repeating: 0, count: Int(gap * Double(Self.sampleRate)))
            var joined: [Float] = []
            for (index, samples) in audio.enumerated() {
                if index > 0 { joined += silence }
                joined += samples
            }
            var spans: [[SpeakerSpan]] = []
            do {
                for diarizer in installed {
                    try Task.checkCancellation()
                    spans.append(try await diarizer.spans(of: joined))
                }
                try Task.checkCancellation()
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if voices.error == nil { voices.error = error.localizedDescription }
                continue
            }
            let speakers = VoiceAgreement.agree(
                ranges.map { VoiceAgreement.speaker(of: $0, in: spans[0]) },
                ranges.map { VoiceAgreement.speaker(of: $0, in: spans[1]) }
            )
            for (record, speaker) in zip(clips, speakers) {
                voices.byClip[record.id] = (speaker == nil ? .disputed : .agreed, speaker)
            }
        }
        return voices
    }

    /// The clip's audio, or nil when it is missing, unreadable or not 16 kHz.
    static func samples(of record: ClipRecord, in folder: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: ClipsFolder.audioURL(for: record.id, in: folder)),
              let decoded = try? WAV.decode(data),
              decoded.sampleRate == sampleRate
        else { return nil }
        return decoded.samples
    }
}
