// 顶栏的原生面板共用的：颜色、尺寸、几种行、面板本身，和每个面板 App 的主循环（runPanelApp）。
// 每个面板是一个单独的小 App（../../aero panel 编译、启动）：fantastic-i3-wifi（wifi.swift）、fantastic-i3-bluetooth
// （bluetooth.swift），各自编译时带上这个文件。不放在 SketchyBar 里：要搜索框、密码框；独立成 App：macOS 只把 Wi-Fi 名称
// 给有定位权限的程序、读蓝牙设备要蓝牙权限，这些权限都只能给 App（第一次启动时系统问一次，之后记住）。
// 样式和 SketchyBar 的面板一样：宽 300、系统菜单材质、左右留 16、上下留 8，能点的行鼠标移上去一块圆角亮底。

import AppKit

let stateDir = "/tmp/yabai-aero-\(NSUserName())"
let sketchybarPath = "/opt/homebrew/bin/sketchybar"
let openIcon = NSString("~/.config/sketchybar/icons/open.png").expandingTildeInPath
let openHoverIcon = NSString("~/.config/sketchybar/icons/open-hover.png").expandingTildeInPath

// 颜色和 ../../sketchybar/colors.sh 一样（0xAARRGGBB）
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: CGFloat(hex >> 24) / 255)
}
let primary = color(0xffeaeaea), secondary = color(0x99ffffff), tertiary = color(0x66ffffff)
let separatorColor = color(0x24ffffff), hoverColor = color(0x26ffffff), pressedColor = color(0x40ffffff)
let green = color(0xff98c379), yellow = color(0xffe5c07b), red = color(0xffe06c75), cyan = color(0xff56b6c2), blue = color(0xff61afef)

// 尺寸和 sketchybarrc 的 POPUP_WIDTH / POPUP_PAD / HL_INSET、backdrop.swift 的 panelRadius / panelInset 一样
let panelWidth: CGFloat = 300, pad: CGFloat = 16, hlInset: CGFloat = 8, radius: CGFloat = 12, vInset: CGFloat = 8
let rowHeight: CGFloat = 26, valueColumn: CGFloat = 110, listMaxRows = 8

/// 顶栏的主题（color / mono），黑白主题下标题的图标也是白的
var barTheme: String { UserDefaults(suiteName: "fantastic-i3.sketchybar")?.string(forKey: "theme") ?? "color" }

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = primary) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

func fixedHeight(_ view: NSView, _ height: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
}

/// 一行灰色的提示（"蓝牙已关闭"之类）
func messageRow(_ text: String) -> NSView {
    let row = NSView()
    fixedHeight(row, rowHeight)
    let message = label(text, color: tertiary)
    row.addSubview(message)
    NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
                                 message.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -pad),
                                 message.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
    return row
}

/// 一行：左边灰色的名称，右边的值（和 SketchyBar 面板的行一样，值从 16 + 110 开始）
final class InfoRow: NSView {
    let name: NSTextField, value = label("—", weight: .medium)
    init(_ title: String, value text: String = "—") {
        name = label(title, color: secondary)
        super.init(frame: .zero)
        value.stringValue = text
        fixedHeight(self, rowHeight)
        addSubview(name)
        addSubview(value)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + valueColumn),
            value.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 能点的行：两边缩进 8，鼠标移上去一块圆角亮底，按下时更亮（和 SketchyBar 面板里能点的行一样）
class HoverRow: NSView {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    let highlight = NSView()
    var hovering = false { didSet { update(); if hovering != oldValue { onHover?(hovering) } } }
    var pressed = false { didSet { update() } }
    var selected = false { didSet { update() } }   // 展开着的那一行一直亮着

    init(height: CGFloat = rowHeight) {
        super.init(frame: .zero)
        fixedHeight(self, height)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hlInset),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hlInset),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        highlight.layer?.backgroundColor = (pressed ? pressedColor : hovering || selected ? hoverColor : .clear).cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 列表里的一项：左边一个系统图标，名字，右边一段灰色小字（已连接、电量……）
final class ListRow: HoverRow {
    init(symbol: NSImage?, tint: NSColor, title: String, bold: Bool, detail: String, trailing: NSImage? = nil) {
        super.init()
        let icon = NSImageView()
        icon.image = symbol
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = label(title, weight: bold ? .semibold : .regular)
        let note = label(detail, size: 11, color: tertiary)
        addSubview(icon)
        addSubview(name)
        addSubview(note)
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let trailing {
            let mark = NSImageView(image: trailing)
            mark.contentTintColor = tertiary
            mark.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark)
            constraints += [mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
                            note.trailingAnchor.constraint(equalTo: mark.leadingAnchor, constant: -6)]
        } else {
            constraints.append(note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad))
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 竖着排的容器：从上往下（NSScrollView 的内容要用翻转的坐标，第一行才在最上面）
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class Panel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }   // Esc
}

func roundedMask(_ radius: CGFloat) -> NSImage {
    let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// 一个面板：系统菜单材质，竖排的行（stack），开在锚点（左上角）下面。点外面、按 Esc 收起。
/// 子类往 stack 里加行，填 willOpen / didOpen / didClose / prepareLayout
class BarPanel: NSObject {
    var panel: Panel!
    let stack = NSStackView()
    var anchorLeft: CGFloat = 0, anchorTop: CGFloat = 30
    var clickMonitor: Any?
    var closedAt = Date.distantPast   // 点面板外面收起的时间：那一下要是点在栏上的那一项上，紧跟着的打开不算
    var timers: [Timer] = []
    var isOpen: Bool { panel?.isVisible ?? false }

    func buildPanel() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onCancel = { [weak self] in self?.close() }
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius)
        let edge = NSView()   // 一圈细亮边，和 SketchyBar 面板后面的材质一样
        edge.wantsLayer = true
        edge.layer?.cornerRadius = radius
        edge.layer?.borderWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        edge.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        edge.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: vInset, left: 0, bottom: vInset, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        effect.addSubview(edge)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: panelWidth),
            edge.topAnchor.constraint(equalTo: effect.topAnchor),
            edge.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            edge.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    func add(_ view: NSView, height: CGFloat? = nil) {
        if let height { fixedHeight(view, height) }
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
    }

    func separator() -> NSView {
        let container = NSView()
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    /// 小标题（灰色小字），和 SketchyBar 面板里的 popup_section 一样
    func sectionHeader(_ title: NSTextField) -> NSView {
        let row = NSView()
        fixedHeight(row, 24)
        row.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -pad),
            title.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    /// 标题行：和栏上一样的图标字形（Maple Mono NF）、标题、右边 ↗；点一下打开对应的系统设置页
    func titleRow(glyph: String, glyphColor: NSColor, title: NSTextField, settings: String) -> NSView {
        let row = HoverRow()
        let icon = NSTextField(labelWithString: glyph)
        icon.font = NSFontManager.shared.font(withFamily: "Maple Mono NF", traits: .boldFontMask, weight: 9, size: 16)
            ?? .systemFont(ofSize: 15)
        icon.textColor = barTheme == "mono" ? .white : glyphColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSImageView(image: NSImage(contentsOfFile: openIcon) ?? NSImage())
        arrow.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(arrow)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -8),
            arrow.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            arrow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 9),
            arrow.heightAnchor.constraint(equalToConstant: 9),
        ])
        row.onHover = { hovering in arrow.image = NSImage(contentsOfFile: hovering ? openHoverIcon : openIcon) }
        row.action = { [weak self] in
            self?.close()
            NSWorkspace.shared.open(URL(string: settings)!)
        }
        return row
    }

    /// 按钮那一行：左边一段状态文字（错误是红的），右边几个按钮，最后一个是默认按钮（回车）
    func buttonRow(_ buttons: [NSButton], status: NSTextField) -> NSView {
        status.isHidden = true
        let line = NSStackView()
        line.orientation = .horizontal
        line.spacing = 8
        line.addArrangedSubview(status)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.forEach { line.addArrangedSubview($0) }
        buttons.last?.keyEquivalent = "\r"
        line.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        fixedHeight(row, 34)
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: pad),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: 打开 / 收起

    func toggle(left: CGFloat, top: CGFloat) {
        if isOpen { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.4 { return }   // 刚因为点在面板外（就是点的栏上那一项）收起
        anchorLeft = left
        anchorTop = top
        willOpen()
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(nil)   // 打开时不把光标放进输入框：不抢键盘
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isOpen else { return }
            self.closedAt = Date()
            self.close()
        }
        didOpen()
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        timers.forEach { $0.invalidate() }
        timers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        didClose()
    }

    /// 面板高度跟内容走，上边贴着锚点不动；右边不超出屏幕
    func layoutPanel() {
        prepareLayout()
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var left = anchorLeft
        if let screen = NSScreen.screens.first(where: { $0.frame.minX <= anchorLeft && anchorLeft < $0.frame.maxX }) {
            left = min(left, screen.frame.maxX - panelWidth - 6)
        }
        panel.setFrame(NSRect(x: left, y: mainHeight - anchorTop - height, width: panelWidth, height: height), display: true)
        panel.invalidateShadow()
    }

    /// 列表放进能滚动的框里：超过 listMaxRows 行就滚动
    func makeScroll(_ list: FlippedStack, _ scroll: NSScrollView) -> NSLayoutConstraint {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        add(scroll)
        let height = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
        height.isActive = true
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return height
    }

    func fitScroll(_ list: FlippedStack, _ height: NSLayoutConstraint) {
        list.layoutSubtreeIfNeeded()
        height.constant = max(min(list.fittingSize.height, CGFloat(listMaxRows) * rowHeight), rowHeight)
    }

    func addToList(_ list: FlippedStack, _ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
    }

    func willOpen() {}
    func didOpen() {}
    func didClose() {}
    func prepareLayout() {}
}

/// 面板 App 的主循环。常驻后台（不在程序坞里）：
///   SIGUSR1：读 anchor 文件（aero panel toggle 写的"<左> <上>"，屏幕坐标，左上角为原点），在那里打开面板，开着就收起
///   SIGUSR2：收起（打开了别的面板、 菜单）
///   SIGHUP： SketchyBar 重新加载过（onHangup，蓝牙面板用来把栏上的图标再推一遍）
/// 点面板外面、按 Esc、切换桌面也收起。
func runPanelApp(anchor: String, make: () -> BarPanel, onHangup: ((BarPanel) -> Void)? = nil) -> Never {
    // 信号先忽略掉（默认动作是退出），下面再接上：aero 可能在这个进程刚启动、还没接好时就发信号
    for number in [SIGUSR1, SIGUSR2, SIGHUP] { signal(number, SIG_IGN) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = make()
    var sources: [DispatchSourceSignal] = []
    func on(_ number: Int32, _ handler: @escaping () -> Void) {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        sources.append(source)
    }
    on(SIGUSR1) {
        let parts = (try? String(contentsOfFile: anchor, encoding: .utf8))?.split(whereSeparator: \.isWhitespace) ?? []
        guard parts.count == 2, let left = Double(parts[0]), let top = Double(parts[1]) else { return }
        panel.toggle(left: left, top: top)
    }
    on(SIGUSR2) { panel.close() }
    on(SIGHUP) { onHangup?(panel) }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                      object: nil, queue: .main) { _ in panel.close() }
    withExtendedLifetime(sources) { app.run() }
    exit(0)
}

