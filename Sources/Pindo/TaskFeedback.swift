import AppKit

enum TaskFeedback: Equatable {
    case added, completed

    func play() {
        let name = self == .added ? "Pop" : "Glass"
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
