import AVFoundation

enum TaskFeedback: String, CaseIterable, Sendable {
    case added, deleted, completed, started

    private static let resources: Bundle = Bundle.main.bundleIdentifier == "com.pindo.Pindo" ? .main : .module

    func play() { TaskFeedbackPlayer.shared.play(self) }

    func makeSound() -> AVAudioPlayer? {
        guard let url = Self.resources.url(forResource: "feedback-\(rawValue)", withExtension: "wav") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }
}

private final class TaskFeedbackPlayer: NSObject, @unchecked Sendable {
    static let shared = TaskFeedbackPlayer()
    // 播放器的创建、播放和释放都在同一条音频队列上，首次打开音频设备时也不会阻塞界面。
    private let queue = DispatchQueue(label: "com.pindo.Pindo.feedback", qos: .userInitiated)
    private var playing: [ObjectIdentifier: AVAudioPlayer] = [:]

    func play(_ feedback: TaskFeedback) {
        queue.async {
            guard let sound = feedback.makeSound() else { return }
            let id = ObjectIdentifier(sound)
            sound.volume = 0.35
            sound.delegate = self
            self.playing[id] = sound
            if !sound.play() { self.playing.removeValue(forKey: id) }
        }
    }
}

extension TaskFeedbackPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        release(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        release(ObjectIdentifier(player))
    }

    private func release(_ id: ObjectIdentifier) {
        queue.async { self.playing.removeValue(forKey: id) }
    }
}
