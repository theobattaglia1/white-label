import SwiftUI
import Observation

/// Holds the workspace layer — versions and notes per track — seeded with the
/// sample catalog. Notes added while listening are kept here for the session.
@Observable
final class WorkspaceStore {
    var versionsByTrack: [String: [Version]] = [:]
    var currentByTrack: [String: String] = [:]
    var notesByTrack: [String: [Note]] = [:]
    var titleOverrides: [String: String] = [:]

    /// Taggable workspace members.
    let members = ["PomPom", "Liz Rose", "Mira Tan", "Hudson", "Alex", "TB"]

    private let notesKey = "wl.notes.v1"
    private let currentKey = "wl.current.v1"
    private let titlesKey = "wl.titles.v1"

    func displayTitle(_ id: String, _ fallback: String) -> String {
        titleOverrides[id] ?? fallback
    }

    func rename(_ id: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { titleOverrides[id] = nil } else { titleOverrides[id] = t }
        persist()
    }

    init() {
        seed()
        loadPersisted()
    }

    func versions(_ track: String) -> [Version] { versionsByTrack[track] ?? [] }

    func currentVersion(_ track: String) -> Version? {
        let id = currentByTrack[track]
        return versions(track).first { $0.id == id } ?? versions(track).last
    }

    func notes(_ track: String) -> [Note] {
        (notesByTrack[track] ?? []).sorted {
            ($0.positionMs ?? Int.max) < ($1.positionMs ?? Int.max)
        }
    }

    func openCount(_ track: String) -> Int { notes(track).filter { !$0.resolved }.count }

    func setCurrent(_ track: String, _ versionID: String) {
        currentByTrack[track] = versionID
        persist()
    }

    func addNote(track: String, positionMs: Int?, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let v = currentVersion(track)?.label ?? "—"
        let note = Note(id: UUID(), positionMs: positionMs, author: "TB", body: trimmed, resolved: false, versionLabel: v)
        notesByTrack[track, default: []].append(note)
        persist()
    }

    func toggleResolved(_ track: String, _ id: UUID) {
        guard var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].resolved.toggle()
        notesByTrack[track] = arr
        persist()
    }

    func updateNote(_ track: String, _ id: UUID, body: String, positionMs: Int?) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let old = arr[i]
        arr[i] = Note(id: old.id, positionMs: positionMs, author: old.author, body: trimmed, resolved: old.resolved, versionLabel: old.versionLabel)
        notesByTrack[track] = arr
        persist()
    }

    func deleteNote(_ track: String, _ id: UUID) {
        notesByTrack[track]?.removeAll { $0.id == id }
        persist()
    }

    // MARK: persistence (local; real API later)

    private func persist() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(notesByTrack) { UserDefaults.standard.set(d, forKey: notesKey) }
        if let d = try? enc.encode(currentByTrack) { UserDefaults.standard.set(d, forKey: currentKey) }
        if let d = try? enc.encode(titleOverrides) { UserDefaults.standard.set(d, forKey: titlesKey) }
    }

    private func loadPersisted() {
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: notesKey),
           let v = try? dec.decode([String: [Note]].self, from: d) {
            notesByTrack = v
        }
        if let d = UserDefaults.standard.data(forKey: currentKey),
           let v = try? dec.decode([String: String].self, from: d) {
            currentByTrack = v
        }
        if let d = UserDefaults.standard.data(forKey: titlesKey),
           let v = try? dec.decode([String: String].self, from: d) {
            titleOverrides = v
        }
    }

    private func seed() {
        versionsByTrack = [
            "first-night": [
                Version(id: "fn1", label: "Rough v1", loudness: "−7.9 LUFS"),
                Version(id: "fn2", label: "Mix v2", loudness: "−8.4 LUFS", approved: true),
                Version(id: "fn3", label: "Mix v3", loudness: "−9.2 LUFS"),
            ],
            "lighting-the-fuse": [
                Version(id: "lf1", label: "Demo v1", loudness: "−8.1 LUFS"),
                Version(id: "lf2", label: "Mix v3", loudness: "−9.0 LUFS"),
            ],
            "duel": [
                Version(id: "du1", label: "Rough v1", loudness: "−7.5 LUFS"),
                Version(id: "du2", label: "Clean v3", loudness: "−12.7 LUFS"),
            ],
            "best-of-me": [
                Version(id: "bm1", label: "Mix v1", loudness: "−8.8 LUFS"),
                Version(id: "bm2", label: "Mix v2", loudness: "−9.4 LUFS"),
            ],
        ]
        currentByTrack = ["first-night": "fn3", "lighting-the-fuse": "lf2", "duel": "du2", "best-of-me": "bm2"]
        notesByTrack = [
            "first-night": [
                Note(id: UUID(), positionMs: 48_000, author: "Liz Rose", body: "The pre-chorus lift still feels early — give it one more bar before the drop.", resolved: false, versionLabel: "Mix v3"),
                Note(id: UUID(), positionMs: 92_000, author: "TB", body: "Vocal sits a touch hot in the second chorus — pull it 1 dB and we’re there.", resolved: false, versionLabel: "Mix v3"),
                Note(id: UUID(), positionMs: 130_000, author: "TB", body: "Snare was clipping into the bridge — fixed.", resolved: true, versionLabel: "Mix v3"),
            ],
            "duel": [
                Note(id: UUID(), positionMs: 64_000, author: "Mira Tan", body: "Love the clean master direction. Ship-adjacent.", resolved: false, versionLabel: "Clean v3"),
            ],
        ]
    }
}
