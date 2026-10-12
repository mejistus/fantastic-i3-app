// 提示条（../capture 用）：鼠标所在屏幕的下方出现一个小胶囊（系统弹出层材质，和 ⌥⇥ 的列表一样），
// 不抢焦点、鼠标点不到，过一会儿淡出。
//   aero-helper toast wait|ok|fail <标题> [详情]   显示一条
//   aero-helper toast                              从标准输入一行一行读 "<样式>\t<标题>\t<详情>"，读到一行就换上新内容
//                                                  （先 wait 转圈，认完换成 ok 或 fail，不会闪一下）
// 样式：wait 转圈，ok 绿色的勾，fail 红色的叉。输入结束后 ok 停 1.6 秒、fail 停 3 秒再淡出；最后是 wait 的直接消失

import AppKit

final class Toast: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let effect = NSVisualEffectView()
    let spinner = NSProgressIndicator()
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let height: CGFloat = 38
    var style = ""
    var screen: NSScreen?
    let arguments: [String]
    var buffer = Data()

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 胶囊形：maskImage 两头是半圆（阴影也跟着走）
        let radius = height / 2
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = mask

        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = effect
        panel.alphaValue = 0

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        for view in [spinner, icon, title, detail] as [NSView] { effect.addSubview(view) }

        if arguments.isEmpty {
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    DispatchQueue.main.async { self.finish() }
                    return
                }
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0a) {
                    let line = String(decoding: self.buffer[..<newline], as: UTF8.self)
                    self.buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { self.show(line.components(separatedBy: "\t")) }
                }
            }
        } else {
            show(arguments)
            finish()
        }
    }

    func show(_ fields: [String]) {
        guard let kind = fields.first, ["wait", "ok", "fail"].contains(kind) else { return }
        style = kind
        title.stringValue = fields.count > 1 ? fields[1] : ""
        detail.stringValue = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""

        let symbol = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        switch kind {
        case "wait":
            icon.isHidden = true
            spinner.startAnimation(nil)
        default:
            spinner.stopAnimation(nil)
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: kind == "ok" ? "checkmark.circle.fill" : "xmark.circle.fill",
                                 accessibilityDescription: nil)?.withSymbolConfiguration(symbol)
            icon.contentTintColor = kind == "ok" ? .systemGreen : .systemRed
        }

        // 一行：图标 ｜ 标题（中等粗细）  详情（次要色，太长截掉）
        let pad: CGFloat = 14, iconSize: CGFloat = 18, gap: CGFloat = 8
        // 宽度按字体量（label 自己报的宽度会受上一次 frame 的影响，变长时截得太早）；+5 是 label 两边的内边距
        func textWidth(_ field: NSTextField) -> CGFloat {
            ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width) + 5
        }
        let titleWidth = textWidth(title)
        let detailWidth = detail.stringValue.isEmpty ? 0 : min(textWidth(detail), 380)
        let width = pad + iconSize + gap + titleWidth + (detailWidth > 0 ? 10 + detailWidth : 0) + pad + 4
        spinner.frame = NSRect(x: pad + 1, y: (height - 16) / 2, width: 16, height: 16)
        icon.frame = NSRect(x: pad, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let textHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: pad + iconSize + gap, y: (height - textHeight) / 2, width: titleWidth, height: textHeight)
        detail.frame = NSRect(x: title.frame.maxX + 10, y: title.frame.minY, width: detailWidth, height: textHeight)
        detail.isHidden = detailWidth == 0

        // 鼠标所在的那块屏，靠下（第一次显示时定下来，换内容时只改宽度，中线不动）
        if screen == nil {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        }
        let frame = screen!.visibleFrame
        panel.setFrame(NSRect(x: (frame.midX - width / 2).rounded(), y: (frame.minY + frame.height * 0.1).rounded(),
                              width: width, height: height), display: true)
        panel.invalidateShadow()
        if !panel.isVisible {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    func finish() {
        guard style == "ok" || style == "fail" else { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == "ok" ? 1.6 : 3)) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 }) { exit(0) }
        }
    }
}
