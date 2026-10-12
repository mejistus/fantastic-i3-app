// Wi-Fi 面板：顶栏网络项点开的面板。一个独立的小 App（~/.cache/fantastic-i3/WiFiPanel.app，由 ../../aero wifi 编译、启动）。
// 独立成 App 是因为 macOS 只把 Wi-Fi 名称（附近的网络、现在连着的网络）给有"定位"权限的程序，而定位权限只能给 App：
// 第一次启动时系统问一次，之后记住。
//
// 常驻后台（不在程序坞里）。收到 SIGUSR1：在 $STATE/wifi-anchor 写的位置（"左 上"，屏幕坐标，左上角为原点）打开面板，
// 开着就收起；SIGUSR2：收起。点面板外面、按 Esc、切换桌面也收起。
//
// 面板（样式和 SketchyBar 的面板一样：宽 300、系统菜单材质、左右留 16、上下留 8，能点的行鼠标移上去一块圆角亮底）：
//   标题行：Wi-Fi · 网络名，点一下打开系统设置的网络页（右边 ↗）
//   现在的连接：下载、上传、IP 地址、路由器、信号、连接速率、信道（每 2 秒刷新）
//   附近的 Wi-Fi：搜索框过滤，每 10 秒重新扫一次。点一个在它下面展开：安全性、账号（企业级）、密码，
//   和"忘记"（存过的才有）、"连接"（连着的是"断开"）。存过的网络不填密码直接连，用钥匙串里存的。

import AppKit
import CoreLocation
import CoreWLAN
import SystemConfiguration

let stateDir = "/tmp/yabai-aero-\(NSUserName())"
let anchorFile = "\(stateDir)/wifi-anchor"
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

// MARK: - 数据

enum SecurityKind { case open, personal, enterprise }

struct WiFiNetwork {
    let ssid: String
    let network: CWNetwork
    let rssi: Int
    let security: String
    let kind: SecurityKind
    var saved: Bool
    var current: Bool
}

func securityOf(_ n: CWNetwork) -> (String, SecurityKind) {
    if n.supportsSecurity(.wpa3Enterprise) { return ("WPA3 企业级", .enterprise) }
    if n.supportsSecurity(.wpa2Enterprise) { return ("WPA2 企业级", .enterprise) }
    if n.supportsSecurity(.wpaEnterprise) || n.supportsSecurity(.wpaEnterpriseMixed) { return ("WPA 企业级", .enterprise) }
    if n.supportsSecurity(.dynamicWEP) { return ("动态 WEP", .enterprise) }
    if n.supportsSecurity(.wpa3Transition) { return ("WPA2/WPA3 个人级", .personal) }
    if n.supportsSecurity(.wpa3Personal) { return ("WPA3 个人级", .personal) }
    if n.supportsSecurity(.wpa2Personal) { return ("WPA2 个人级", .personal) }
    if n.supportsSecurity(.wpaPersonal) || n.supportsSecurity(.wpaPersonalMixed) { return ("WPA 个人级", .personal) }
    if n.supportsSecurity(.WEP) { return ("WEP", .personal) }
    if n.supportsSecurity(.OWE) || n.supportsSecurity(.oweTransition) { return ("增强型开放", .open) }
    return ("无（开放网络）", .open)
}

/// 存过的网络（系统设置里"已知网络"），networksetup 读，不要定位权限
func savedNetworks(_ interface: String) -> Set<String> {
    let output = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interface]).output
    return Set(output.split(separator: "\n").filter { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) })
}

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

/// 某个网卡收发的总字节数（算网速用）
func interfaceBytes(_ name: String) -> (received: UInt64, sent: UInt64)? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        if String(cString: entry.pointee.ifa_name) == name, entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
           let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
            return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        cursor = entry.pointee.ifa_next
    }
    return nil
}

func speedText(_ bytesPerSecond: Double) -> String {
    switch bytesPerSecond {
    case ..<1000: return "\(Int(bytesPerSecond)) B/s"
    case ..<1_000_000: return "\(Int((bytesPerSecond / 1000).rounded())) KB/s"
    default: return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}

// MARK: - 视图

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

/// 一行：左边灰色的名称，右边的值（和 SketchyBar 面板的行一样，值从 16 + 110 开始）
final class InfoRow: NSView {
    let name: NSTextField, value = label("—", weight: .medium)
    init(_ title: String) {
        name = label(title, color: secondary)
        super.init(frame: .zero)
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
    var selected = false { didSet { update() } }   // 展开着的网络那一行一直亮着

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

/// 列表里的一个网络：信号图标、名字、锁（要密码的）
final class NetworkRow: HoverRow {
    init(_ network: WiFiNetwork) {
        super.init()
        let strength: Double = network.rssi >= -55 ? 1 : network.rssi >= -67 ? 0.67 : network.rssi >= -75 ? 0.34 : 0.1
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "wifi", variableValue: strength, accessibilityDescription: nil)
        icon.contentTintColor = network.current ? blue : primary
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = label(network.ssid, weight: network.current ? .semibold : .regular)
        let detail = label(network.current ? "已连接" : network.saved ? "已存储" : "", size: 11, color: tertiary)
        addSubview(icon)
        addSubview(name)
        addSubview(detail)
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if network.kind != .open {
            let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
            lock.contentTintColor = tertiary
            lock.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            lock.translatesAutoresizingMaskIntoConstraints = false
            addSubview(lock)
            constraints += [lock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
                            detail.trailingAnchor.constraint(equalTo: lock.leadingAnchor, constant: -6)]
        } else {
            constraints.append(detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad))
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
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

// MARK: - 面板

final class WiFiPanel: NSObject, CLLocationManagerDelegate, NSSearchFieldDelegate {
    let wifi = CWWiFiClient.shared().interface()
    let location = CLLocationManager()
    let store = SCDynamicStoreCreate(nil, "wifi-panel" as CFString, nil, nil)
    var panel: Panel!
    let stack = NSStackView()
    let titleLabel = label("网络", weight: .semibold)
    let titleIcon = NSTextField(labelWithString: "\u{F05A9}")
    let rows = ["down": InfoRow("下载"), "up": InfoRow("上传"), "ip": InfoRow("IP 地址"), "router": InfoRow("路由器"),
                "signal": InfoRow("信号"), "rate": InfoRow("连接速率"), "channel": InfoRow("信道")]
    let rowOrder = ["down", "up", "ip", "router", "signal", "rate", "channel"]
    let nearbyLabel = label("附近的 Wi-Fi", size: 11, weight: .semibold, color: tertiary)
    let search = NSSearchField()
    let list = FlippedStack()
    let scroll = NSScrollView()
    var scrollHeight: NSLayoutConstraint!
    var networks: [WiFiNetwork] = []
    var expanded: String?            // 展开着的网络
    var scanning = false
    var lastScan = Date.distantPast
    var lastBytes: (bytes: (received: UInt64, sent: UInt64), time: Date, name: String)?
    var timers: [Timer] = []
    var clickMonitor: Any?
    var closedAt = Date.distantPast  // 点面板外面收起的时间：那一下要是点在网络项上，hover.sh 发来的打开不算
    var signals: [DispatchSourceSignal] = []
    var anchorTop: CGFloat = 0, anchorLeft: CGFloat = 0
    // 展开那一块里的控件（每次展开重建）
    var usernameField: NSTextField?, passwordField: NSSecureTextField?, statusLabel: NSTextField?

    func start() {
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        buildPanel()
        let handlers: [(Int32, () -> Void)] = [(SIGUSR1, { [weak self] in self?.toggle() }),
                                                (SIGUSR2, { [weak self] in self?.close() })]
        for (number, handler) in handlers {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            signals.append(source)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.close() }
        scan()   // 先扫一次，第一次打开时列表就有东西
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if panel.isVisible { refreshInfo(); scan(force: true) }
    }

    var locationAllowed: Bool {
        [.authorizedAlways, .authorized].contains(location.authorizationStatus)
    }

    // MARK: 搭面板

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

        add(titleRow())
        add(separator(), height: 9)
        for key in rowOrder { add(rows[key]!) }
        add(separator(), height: 9)
        add(nearbyHeader())
        add(searchRow(), height: 34)

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
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
        scrollHeight.isActive = true
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    func add(_ view: NSView, height: CGFloat? = nil) {
        if let height { fixedHeight(view, height) }
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
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

    /// 标题行：网络图标（和栏上一样的字形）、Wi-Fi · 网络名、右边 ↗；点一下打开系统设置的网络页
    func titleRow() -> NSView {
        let row = HoverRow()
        let theme = UserDefaults(suiteName: "fantastic-i3.sketchybar")?.string(forKey: "theme") ?? "color"
        titleIcon.font = NSFontManager.shared.font(withFamily: "Maple Mono NF", traits: .boldFontMask, weight: 9, size: 16)
            ?? .systemFont(ofSize: 15)
        titleIcon.textColor = theme == "mono" ? .white : cyan
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSImageView(image: NSImage(contentsOfFile: openIcon) ?? NSImage())
        arrow.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleIcon)
        row.addSubview(titleLabel)
        row.addSubview(arrow)
        NSLayoutConstraint.activate([
            titleIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            titleIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -8),
            arrow.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            arrow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 9),
            arrow.heightAnchor.constraint(equalToConstant: 9),
        ])
        row.onHover = { hovering in arrow.image = NSImage(contentsOfFile: hovering ? openHoverIcon : openIcon) }
        row.action = { [weak self] in
            self?.close()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        }
        return row
    }

    func nearbyHeader() -> NSView {
        let row = NSView()
        fixedHeight(row, 24)
        row.addSubview(nearbyLabel)
        NSLayoutConstraint.activate([
            nearbyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            nearbyLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -pad),
            nearbyLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    func searchRow() -> NSView {
        let row = NSView()
        search.placeholderString = "搜索"
        search.delegate = self
        search.focusRingType = .none
        search.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            search.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            search.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { reloadList() }
    }

    // MARK: 打开 / 收起

    func toggle() {
        if panel.isVisible { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.4 { return }   // 刚因为点在面板外（就是点的网络项）收起
        open()
    }

    func open() {
        let anchor = (try? String(contentsOfFile: anchorFile, encoding: .utf8))?
            .split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        anchorLeft = anchor.count > 0 ? anchor[0] : 0
        anchorTop = anchor.count > 1 ? anchor[1] : 30
        expanded = nil
        search.stringValue = ""
        lastBytes = nil
        refreshInfo()
        reloadList()
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(nil)   // 先不把光标放进搜索框：打开面板时不抢键盘
        timers = [Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshInfo() },
                  Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(force: true) },
                  Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.refreshInfo() }]
        scan(force: Date().timeIntervalSince(lastScan) > 5)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.closedAt = Date()
            self.close()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        timers.forEach { $0.invalidate() }
        timers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// 面板高度跟内容走，上边贴着锚点不动
    func layoutPanel() {
        let visible = min(listRowsHeight(), CGFloat(listMaxRows) * rowHeight)
        scrollHeight.constant = max(visible, rowHeight)
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

    func listRowsHeight() -> CGFloat {
        list.layoutSubtreeIfNeeded()
        return list.fittingSize.height
    }

    // MARK: 现在的连接

    func refreshInfo() {
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let name = global?["PrimaryInterface"] as? String ?? ""
        let isWiFi = !name.isEmpty && name == wifi?.interfaceName
        let kind = name.isEmpty ? "未连接" : isWiFi ? "Wi-Fi" : name.hasPrefix("utun") || name.hasPrefix("ppp") ? "VPN" : "以太网"
        let ssid = isWiFi ? wifi?.ssid() : nil
        titleLabel.stringValue = name.isEmpty ? kind : "\(kind) · \(ssid ?? name)"

        var ip = "—"
        if !name.isEmpty, let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/IPv4" as CFString) as? [String: Any],
           let address = (v4["Addresses"] as? [String])?.first { ip = address }
        rows["ip"]!.value.stringValue = ip
        rows["router"]!.value.stringValue = global?["Router"] as? String ?? "—"

        if let bytes = interfaceBytes(name), let last = lastBytes, last.name == name {
            let seconds = max(Date().timeIntervalSince(last.time), 0.1)
            rows["down"]!.value.stringValue = speedText(Double(bytes.received &- last.bytes.received) / seconds)
            rows["up"]!.value.stringValue = speedText(Double(bytes.sent &- last.bytes.sent) / seconds)
        } else {
            rows["down"]!.value.stringValue = "—"
            rows["up"]!.value.stringValue = "—"
        }
        if let bytes = interfaceBytes(name) { lastBytes = (bytes, Date(), name) }

        let wifiRows = ["signal", "rate", "channel"]
        if let wifi, wifi.rssiValue() != 0 {
            let rssi = wifi.rssiValue()
            let quality = rssi >= -55 ? ("极好", green) : rssi >= -67 ? ("良好", green) : rssi >= -75 ? ("一般", yellow) : ("较差", red)
            rows["signal"]!.value.stringValue = "\(rssi) dBm（\(quality.0)）"
            rows["signal"]!.value.textColor = quality.1
            rows["rate"]!.value.stringValue = String(format: "%.0f Mbps", wifi.transmitRate())
            if let channel = wifi.wlanChannel() {
                let band = [CWChannelBand.band2GHz: "2.4 GHz", .band5GHz: "5 GHz", .band6GHz: "6 GHz"][channel.channelBand] ?? ""
                rows["channel"]!.value.stringValue = "\(channel.channelNumber)\(band.isEmpty ? "" : "（\(band)）")"
            }
            wifiRows.forEach { rows[$0]!.isHidden = false }
        } else {
            wifiRows.forEach { rows[$0]!.isHidden = true }
        }
    }

    // MARK: 附近的 Wi-Fi

    func scan(force: Bool = false) {
        guard let wifi, !scanning, force || networks.isEmpty else { return }
        scanning = true
        updateNearbyLabel()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = (try? wifi.scanForNetworks(withSSID: nil)) ?? []
            let saved = savedNetworks(wifi.interfaceName ?? "en0")
            let current = wifi.ssid()
            var best: [String: CWNetwork] = [:]
            for network in found {
                guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                if let old = best[ssid], old.rssiValue >= network.rssiValue { continue }
                best[ssid] = network
            }
            let list = best.map { ssid, network -> WiFiNetwork in
                let security = securityOf(network)
                return WiFiNetwork(ssid: ssid, network: network, rssi: network.rssiValue, security: security.0,
                                   kind: security.1, saved: saved.contains(ssid), current: ssid == current)
            }.sorted { a, b in
                if a.current != b.current { return a.current }
                if a.saved != b.saved { return a.saved }
                return a.rssi > b.rssi
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.lastScan = Date()
                self.networks = list
                self.updateNearbyLabel()
                if self.panel.isVisible && !self.editing { self.reloadList() }
            }
        }
    }

    /// 正在填账号 / 密码时不重建列表（重建会把输入框换掉）
    var editing: Bool {
        guard let responder = panel.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: list)
    }

    func updateNearbyLabel() {
        nearbyLabel.stringValue = scanning && networks.isEmpty ? "附近的 Wi-Fi · 正在扫描…" : "附近的 Wi-Fi"
    }

    func reloadList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        usernameField = nil
        passwordField = nil
        statusLabel = nil
        if !locationAllowed {
            let row = HoverRow(height: 44)
            let text = label("要看到 Wi-Fi 名称，需要允许定位权限\n点这里打开 系统设置 › 隐私与安全性 › 定位服务", size: 11, color: secondary)
            text.maximumNumberOfLines = 2
            row.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
                                         text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
                                         text.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
            row.action = { [weak self] in
                self?.close()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            }
            addToList(row)
        } else {
            let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = networks.filter { query.isEmpty || $0.ssid.lowercased().contains(query) }
            if shown.isEmpty {
                let row = NSView()
                fixedHeight(row, rowHeight)
                let text = label(scanning ? "正在扫描…" : query.isEmpty ? "附近没有 Wi-Fi" : "没有名字里带“\(query)”的网络",
                                 color: tertiary)
                row.addSubview(text)
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
                                             text.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
                addToList(row)
            }
            for network in shown {
                let row = NetworkRow(network)
                row.selected = expanded == network.ssid
                row.action = { [weak self] in self?.toggleExpanded(network.ssid) }
                addToList(row)
                if expanded == network.ssid { addToList(detail(network)) }
            }
        }
        if panel.isVisible { layoutPanel() }
    }

    func addToList(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
    }

    func toggleExpanded(_ ssid: String) {
        expanded = expanded == ssid ? nil : ssid
        reloadList()
        // 展开了要密码的网络：光标直接放进第一个输入框
        if let field = usernameField ?? passwordField { panel.makeFirstResponder(field) }
        if let index = list.arrangedSubviews.firstIndex(where: { ($0 as? NetworkRow)?.selected == true }) {
            list.arrangedSubviews[index].scrollToVisible(list.arrangedSubviews[index].bounds)
        }
    }

    /// 展开那一块：安全性、账号（企业级）、密码，按钮
    func detail(_ network: WiFiNetwork) -> NSView {
        let box = FlippedStack()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 0
        box.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        func put(_ view: NSView) {
            box.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
        }
        let security = InfoRow("安全性")
        security.value.stringValue = network.security
        put(security)
        if network.saved && network.kind != .open && !network.current {
            let hint = label("存过密码，留空直接连", size: 11, color: tertiary)
            let row = NSView()
            fixedHeight(row, 18)
            row.addSubview(hint)
            NSLayoutConstraint.activate([hint.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad + valueColumn),
                                         hint.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
            put(row)
        }
        if network.kind == .enterprise && !network.current {
            let field = NSTextField()
            field.placeholderString = "账号"
            usernameField = field
            put(fieldRow("账号", field))
        }
        if network.kind != .open && !network.current {
            let field = NSSecureTextField()
            field.placeholderString = "密码"
            field.target = self
            field.action = #selector(connectExpanded)
            passwordField = field
            put(fieldRow("密码", field))
            usernameField?.nextKeyView = field
        }

        let status = label("", size: 11, color: red)
        status.isHidden = true
        statusLabel = status
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(status)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if network.saved {
            buttons.addArrangedSubview(button("忘记", #selector(forgetExpanded)))
        }
        let main = button(network.current ? "断开" : "连接", network.current ? #selector(disconnect) : #selector(connectExpanded))
        main.keyEquivalent = "\r"
        buttons.addArrangedSubview(main)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        fixedHeight(row, 34)
        row.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: pad),
            buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            buttons.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        put(row)
        return box
    }

    func fieldRow(_ title: String, _ field: NSTextField) -> NSView {
        let row = NSView()
        fixedHeight(row, 30)
        let name = label(title, color: secondary)
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad + valueColumn),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    // MARK: 连接 / 断开 / 忘记

    var expandedNetwork: WiFiNetwork? { networks.first { $0.ssid == expanded } }

    func showStatus(_ text: String, error: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = error ? red : secondary
        statusLabel?.isHidden = text.isEmpty
    }

    @objc func connectExpanded() {
        guard let network = expandedNetwork, let wifi else { return }
        if network.current { return }
        let username = usernameField?.stringValue ?? "", password = passwordField?.stringValue ?? ""
        showStatus("正在连接…", error: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                switch network.kind {
                case .enterprise:
                    try wifi.associate(toEnterpriseNetwork: network.network, identity: nil,
                                       username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password)
                case .personal where password.isEmpty && network.saved:
                    // 存过的网络不填密码：networksetup 用钥匙串里存的密码连
                    let result = run("/usr/sbin/networksetup", ["-setairportnetwork", wifi.interfaceName ?? "en0", network.ssid])
                    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.status != 0 || !output.isEmpty { failure = output.isEmpty ? "连接失败" : output }
                default:
                    try wifi.associate(to: network.network, password: password.isEmpty ? nil : password)
                }
            } catch {
                failure = (error as NSError).localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.showStatus(failure, error: true)
                } else {
                    self.expanded = nil
                    self.refreshInfo()
                    self.scan(force: true)
                    self.reloadList()
                }
            }
        }
    }

    @objc func disconnect() {
        wifi?.disassociate()
        expanded = nil
        refreshInfo()
        scan(force: true)
        reloadList()
    }

    /// 忘记：从"已知网络"里删掉。要管理员权限：先直接试，不行就弹系统的密码框
    @objc func forgetExpanded() {
        guard let network = expandedNetwork, let wifi else { return }
        let interface = wifi.interfaceName ?? "en0"
        showStatus("正在忘记…", error: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = run("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", interface, network.ssid])
            if result.status != 0 || result.output.localizedCaseInsensitiveContains("error") {
                result = run("/usr/bin/osascript", [
                    "-e", "on run {ifc, ssid}",
                    "-e", "do shell script \"/usr/sbin/networksetup -removepreferredwirelessnetwork \" & quoted form of ifc & \" \" & quoted form of ssid with administrator privileges",
                    "-e", "end run", interface, network.ssid])
            }
            let saved = savedNetworks(interface)
            DispatchQueue.main.async {
                guard let self else { return }
                if saved.contains(network.ssid) {
                    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.showStatus(output.isEmpty ? "没能忘记这个网络" : output, error: true)
                } else {
                    for i in self.networks.indices where self.networks[i].ssid == network.ssid { self.networks[i].saved = false }
                    self.reloadList()
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = WiFiPanel()
controller.start()
app.run()
