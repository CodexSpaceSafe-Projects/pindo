import AppKit
import SwiftUI

private struct GroupColorPreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    // Paul Tol 的 Bright 分类色板：用不同色相区分分组，菜单同时显示颜色名称。
    // https://sronpersonalpages.nl/~pault/data/colourschemes.pdf（图 1）
    static let palette = [
        Self(name: "蓝色", hex: "#4477AA"), Self(name: "青色", hex: "#66CCEE"),
        Self(name: "绿色", hex: "#228833"), Self(name: "黄色", hex: "#CCBB44"),
        Self(name: "红色", hex: "#EE6677"), Self(name: "紫色", hex: "#AA3377"),
        Self(name: "灰色", hex: "#BBBBBB")
    ]

    var swatch: NSImage {
        let color = NSColor(Color(hex: hex))
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            shape.fill()
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            shape.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct GroupColorMenu: View {
    @Environment(\.pindoLocalization) private var l10n
    @Binding var colorHex: String
    let accessibilityName: String

    static let defaultColor = GroupColorPreset.palette[0].hex

    var body: some View {
        Menu {
            ForEach(GroupColorPreset.palette) { preset in
                Button {
                    GroupColorEditor.shared.close()
                    if colorHex.uppercased() != preset.hex { colorHex = preset.hex }
                } label: {
                    Label { Text(l10n(preset.name)) } icon: { Image(nsImage: preset.swatch) }
                }
            }
            Divider()
            Button(l10n("自定义颜色…")) {
                GroupColorEditor.shared.show(colorHex: colorHex) { colorHex = $0 }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: colorHex)).frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 1))
                Text(l10n(GroupColorPreset.palette.first { $0.hex == colorHex.uppercased() }?.name ?? "自定义颜色"))
                    .lineLimit(1)
            }
        }.fixedSize().accessibilityLabel(accessibilityName)
    }
}

@MainActor final class GroupColorEditor: NSObject, NSWindowDelegate {
    static let shared = GroupColorEditor()
    private weak var panel: NSColorPanel?
    private var onChange: ((String) -> Void)?
    private var lastHex: String?

    func show(colorHex: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil); panel.setAction(nil)
        panel.showsAlpha = false; panel.isContinuous = false
        panel.color = NSColor(Color(hex: colorHex))
        self.panel = panel; self.onChange = onChange; lastHex = colorHex.uppercased()
        panel.delegate = self
        panel.setTarget(self); panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        let hex = "#" + components.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
        guard hex != lastHex else { return }
        lastHex = hex
        onChange?(hex)
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel?.setTarget(nil); panel?.setAction(nil); panel?.delegate = nil
        panel = nil; onChange = nil; lastHex = nil
    }
}
