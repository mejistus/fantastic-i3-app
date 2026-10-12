// Wi-Fi 面板：顶栏网络项点开的面板。
//   标题行：Wi-Fi · 网络名，点一下打开系统设置的网络页（右边 ↗）
//   现在的连接：下载、上传、IP 地址、路由器、信号、连接速率、信道（每 2 秒刷新）
//   附近的 Wi-Fi：搜索框过滤，每 10 秒重新扫一次。点一个在它下面展开：安全性、账号（企业级）、密码，
//   和"忘记"（存过的才有）、"连接"（连着的是"断开"）。存过的网络不填密码直接连，用钥匙串里存的。
// 单独的小 App：fantastic-i3-wifi（common.swift 的 runPanelApp）。Wi-Fi 名称（附近的、现在连着的）要定位权限，
// 第一次启动时系统问一次。

import AppKit
import CoreLocation
import CoreWLAN
import SystemConfiguration

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

final class WiFiPanel: BarPanel, CLLocationManagerDelegate, NSSearchFieldDelegate {
    let wifi = CWWiFiClient.shared().interface()
    let location = CLLocationManager()
    let store = SCDynamicStoreCreate(nil, "fantastic-i3-wifi" as CFString, nil, nil)
    let titleLabel = label("网络", weight: .semibold)
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
    // 展开那一块里的控件（每次展开重建）
    var usernameField: NSTextField?, passwordField: NSSecureTextField?, statusLabel: NSTextField?

    func start() {
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        buildPanel()
        add(titleRow(glyph: "\u{F05A9}", glyphColor: cyan, title: titleLabel,
                     settings: "x-apple.systempreferences:com.apple.Network-Settings.extension"))
        add(separator(), height: 9)
        for key in rowOrder { add(rows[key]!) }
        add(separator(), height: 9)
        add(sectionHeader(nearbyLabel))
        add(searchRow(), height: 34)
        scrollHeight = makeScroll(list, scroll)
        scan()   // 先扫一次，第一次打开时列表就有东西
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isOpen { refreshInfo(); scan(force: true); reloadList() }
    }

    var locationAllowed: Bool {
        [.authorizedAlways, .authorized].contains(location.authorizationStatus)
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

    override func willOpen() {
        expanded = nil
        search.stringValue = ""
        lastBytes = nil
        refreshInfo()
        reloadList()
    }

    override func didOpen() {
        timers = [Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshInfo() },
                  Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(force: true) },
                  Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.refreshInfo() }]
        scan(force: Date().timeIntervalSince(lastScan) > 5)
    }

    override func prepareLayout() { fitScroll(list, scrollHeight) }

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
                if self.isOpen && !self.editing { self.reloadList() }
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
            addToList(list, row)
        } else {
            let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = networks.filter { query.isEmpty || $0.ssid.lowercased().contains(query) }
            if shown.isEmpty {
                addToList(list, messageRow(scanning ? "正在扫描…" : query.isEmpty ? "附近没有 Wi-Fi" : "没有名字里带“\(query)”的网络"))
            }
            for network in shown {
                let strength: Double = network.rssi >= -55 ? 1 : network.rssi >= -67 ? 0.67 : network.rssi >= -75 ? 0.34 : 0.1
                let row = ListRow(symbol: NSImage(systemSymbolName: "wifi", variableValue: strength, accessibilityDescription: nil),
                                  tint: network.current ? blue : primary, title: network.ssid, bold: network.current,
                                  detail: network.current ? "已连接" : network.saved ? "已存储" : "",
                                  trailing: network.kind == .open ? nil : NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil))
                row.selected = expanded == network.ssid
                row.action = { [weak self] in self?.toggleExpanded(network.ssid) }
                addToList(list, row)
                if expanded == network.ssid { addToList(list, detail(network)) }
            }
        }
        if isOpen { layoutPanel() }
    }

    func toggleExpanded(_ ssid: String) {
        expanded = expanded == ssid ? nil : ssid
        reloadList()
        // 展开了要密码的网络：光标直接放进第一个输入框
        if let field = usernameField ?? passwordField { panel.makeFirstResponder(field) }
        if let row = list.arrangedSubviews.first(where: { ($0 as? HoverRow)?.selected == true }) {
            row.scrollToVisible(row.bounds)
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
        put(InfoRow("安全性", value: network.security))
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
        statusLabel = status
        var buttons: [NSButton] = []
        if network.saved { buttons.append(button("忘记", #selector(forgetExpanded))) }
        buttons.append(network.current ? button("断开", #selector(disconnect)) : button("连接", #selector(connectExpanded)))
        put(buttonRow(buttons, status: status))
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

    // MARK: 连接 / 断开 / 忘记

    var expandedNetwork: WiFiNetwork? { networks.first { $0.ssid == expanded } }

    func showStatus(_ text: String, error: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = error ? red : secondary
        statusLabel?.isHidden = text.isEmpty
    }

    @objc func connectExpanded() {
        guard let network = expandedNetwork, let wifi, !network.current else { return }
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

@main
enum WiFiApp {
    static func main() {
        runPanelApp(anchor: "\(stateDir)/wifi-anchor") {
            let panel = WiFiPanel()
            panel.start()
            return panel
        }
    }
}

