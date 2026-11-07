import AppKit

enum TaskFeedback: Equatable {
    case added, completed

    @MainActor func play() { TaskFeedbackPlayer.shared.play(self) }

    @MainActor func makeSound() -> NSSound? {
        let name = self == .added ? "Pop" : "Glass"
        // 系统会缓存命名音效；每个事件需要独立的播放状态。
        return NSSound(named: NSSound.Name(name))?.copy() as? NSSound
    }
}

@MainActor private final class TaskFeedbackPlayer: NSObject, NSSoundDelegate {
    static let shared = TaskFeedbackPlayer()
    private var playing: [ObjectIdentifier: NSSound] = [:]

    func play(_ feedback: TaskFeedback) {
        guard let sound = feedback.makeSound() else { return }
        let id = ObjectIdentifier(sound)
        sound.volume = 0.35
        sound.delegate = self
        playing[id] = sound
        if !sound.play() { playing.removeValue(forKey: id) }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing.removeValue(forKey: ObjectIdentifier(sound))
    }
}
