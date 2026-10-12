// 蓝牙面板：顶栏蓝牙项点开的面板（和控制中心的蓝牙模块差不多）。
//   标题行：蓝牙，点一下打开系统设置的蓝牙页（右边 ↗）
//   蓝牙总开关
//   我的设备：配对过的设备，连着的在前面（图标是蓝的，右边是电量或"已连接"）。点一个在它下面展开：
//   类型、地址、电量，和"忘记""连接 / 断开"
// 栏上的蓝牙图标也由这里推：开着是蓝牙图标，关着是灰的、带斜线的（有设备连着也不加两边的点，太花）；
// 设备连上 / 断开、开关时马上推，另外每 5 秒看一次。
// 单独的小 App：fantastic-i3-bluetooth（common.swift 的 runPanelApp）。读蓝牙设备要"蓝牙"权限，第一次启动时系统问一次。

import AppKit
import IOBluetooth

/// 蓝牙总开关：系统设置里那个开关用的函数（不公开，blueutil 也是这么做的）
let bluetoothFramework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
func bluetoothPower() -> Bool {
    typealias Get = @convention(c) () -> Int32
    guard let function = dlsym(bluetoothFramework, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
    return unsafeBitCast(function, to: Get.self)() != 0
}
func setBluetoothPower(_ on: Bool) {
    typealias Set = @convention(c) (Int32) -> Void
    guard let function = dlsym(bluetoothFramework, "IOBluetoothPreferenceSetControllerPowerState") else { return }
    unsafeBitCast(function, to: Set.self)(on ? 1 : 0)
}

struct BluetoothDevice {
    let device: IOBluetoothDevice
    let name: String
    let address: String
    let connected: Bool
    let kind: String
    let symbol: String
    let battery: String?
}

func pairedDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
}

/// 设备类型（蓝牙的设备类别）和对应的系统图标
func deviceKind(_ device: IOBluetoothDevice) -> (String, String) {
    let minor = device.deviceClassMinor
    switch device.deviceClassMajor {
    case 0x01: return ("电脑", "laptopcomputer")
    case 0x02: return ("手机", "iphone")
    case 0x04: return minor == 0x05 ? ("音箱", "hifispeaker") : ("耳机", "headphones")
    case 0x05:
        if minor & 0x30 == 0x30 { return ("键盘和鼠标", "keyboard") }
        if minor & 0x10 != 0 { return ("键盘", "keyboard") }
        if minor & 0x20 != 0 { return ("鼠标 / 触控板", "computermouse") }
        if minor & 0x0f == 0x01 || minor & 0x0f == 0x02 { return ("游戏手柄", "gamecontroller") }
        return ("外设", "dot.radiowaves.left.and.right")
    case 0x07: return ("穿戴设备", "applewatch")
    default: return ("设备", "dot.radiowaves.left.and.right")
    }
}

/// 电量：苹果的设备（AirPods、妙控键盘 / 鼠标 / 板）会报，别的多半没有。属性不公开，先问它有没有再读
func batteryText(_ device: IOBluetoothDevice) -> String? {
    func percent(_ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
        return value.intValue
    }
    if let left = percent("batteryPercentLeft"), let right = percent("batteryPercentRight") {
        let box = percent("batteryPercentCase").map { " · 盒 \($0)%" } ?? ""
        return "左 \(left)% · 右 \(right)%\(box)"
    }
    if let single = percent("batteryPercentSingle") ?? percent("batteryPercentCombined") { return "\(single)%" }
    return nil
}

func deviceInfo(_ device: IOBluetoothDevice) -> BluetoothDevice {
    let kind = deviceKind(device)
    return BluetoothDevice(device: device, name: device.nameOrAddress ?? "未知设备", address: device.addressString ?? "",
                           connected: device.isConnected(), kind: kind.0, symbol: kind.1, battery: batteryText(device))
}

final class BluetoothPanel: BarPanel {
    let titleLabel = label("蓝牙", weight: .semibold)
    let powerSwitch = NSSwitch()
    let devicesLabel = label("我的设备", size: 11, weight: .semibold, color: tertiary)
    let list = FlippedStack()
    let scroll = NSScrollView()
    var scrollHeight: NSLayoutConstraint!
    var devices: [BluetoothDevice] = []
    var expanded: String?   // 展开着的设备地址
    var statusLabel: NSTextField?
    var lastBar = ""
    var connectNotification: IOBluetoothUserNotification?

    func start() {
        buildPanel()
        add(titleRow(glyph: "\u{F00AF}", glyphColor: blue, title: titleLabel,
                     settings: "x-apple.systempreferences:com.apple.BluetoothSettings"))
        add(separator(), height: 9)
        add(powerRow())
        add(separator(), height: 9)
        add(sectionHeader(devicesLabel))
        scrollHeight = makeScroll(list, scroll)
        // 设备连上时通知（之后再单独登记它断开的通知）；已经连着的设备先登记断开通知
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
        for device in pairedDevices() where device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pushBar() }
        pushBar(force: true)
    }

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        changed()
    }

    @objc func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        changed()
    }

    func changed() {
        pushBar()
        if isOpen { reload() }
    }

    /// 栏上的蓝牙图标：开着、关着（灰）。和上次一样就不推（SketchyBar 重新加载后 aero 发 SIGHUP，强推一次）
    func pushBar(force: Bool = false) {
        let on = bluetoothPower()
        let icon = on ? "\u{F00AF}" : "\u{F00B2}"
        let tint = !on ? "0x73ffffff" : barTheme == "mono" ? "0xffffffff" : "0xff61afef"
        guard force || icon + tint != lastBar else { return }
        lastBar = icon + tint
        DispatchQueue.global(qos: .utility).async {
            run(sketchybarPath, ["--set", "bluetooth", "icon=\(icon)", "icon.color=\(tint)"])
        }
    }

    func powerRow() -> NSView {
        let row = NSView()
        fixedHeight(row, 32)
        let name = label("蓝牙")
        powerSwitch.target = self
        powerSwitch.action = #selector(togglePower)
        powerSwitch.controlSize = .small
        powerSwitch.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)
        row.addSubview(powerSwitch)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            powerSwitch.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            powerSwitch.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc func togglePower() {
        setBluetoothPower(powerSwitch.state == .on)
        expanded = nil
        // 开关要一会儿才生效
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.changed() }
        }
    }

    override func willOpen() {
        expanded = nil
        reload()
    }

    override func prepareLayout() { fitScroll(list, scrollHeight) }

    func reload() {
        let on = bluetoothPower()
        powerSwitch.state = on ? .on : .off
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusLabel = nil
        if !on {
            devices = []
            addToList(list, messageRow("蓝牙已关闭"))
        } else {
            devices = pairedDevices().map(deviceInfo).sorted { a, b in
                a.connected != b.connected ? a.connected : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if devices.isEmpty { addToList(list, messageRow("没有配对过的设备")) }
            for device in devices {
                let row = ListRow(symbol: NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil),
                                  tint: device.connected ? blue : primary, title: device.name, bold: device.connected,
                                  detail: device.connected ? (device.battery ?? "已连接") : "")
                row.selected = expanded == device.address
                row.action = { [weak self] in self?.toggleExpanded(device.address) }
                addToList(list, row)
                if expanded == device.address { addToList(list, detail(device)) }
            }
        }
        if isOpen { layoutPanel() }
    }

    func toggleExpanded(_ address: String) {
        expanded = expanded == address ? nil : address
        reload()
        if let row = list.arrangedSubviews.first(where: { ($0 as? HoverRow)?.selected == true }) {
            row.scrollToVisible(row.bounds)
        }
    }

    /// 展开那一块：类型、地址、电量，按钮
    func detail(_ device: BluetoothDevice) -> NSView {
        let box = FlippedStack()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 0
        box.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        func put(_ view: NSView) {
            box.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
        }
        put(InfoRow("类型", value: device.kind))
        put(InfoRow("地址", value: device.address.uppercased()))
        if let battery = device.battery { put(InfoRow("电量", value: battery)) }
        let status = label("", size: 11, color: red)
        statusLabel = status
        put(buttonRow([button("忘记", #selector(forgetExpanded)),
                       device.connected ? button("断开", #selector(connectExpanded)) : button("连接", #selector(connectExpanded))],
                      status: status))
        return box
    }

    // MARK: 连接 / 断开 / 忘记

    var expandedDevice: BluetoothDevice? { devices.first { $0.address == expanded } }

    func showStatus(_ text: String, error: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = error ? red : secondary
        statusLabel?.isHidden = text.isEmpty
    }

    /// 连着就断开，没连就连（连接要几秒，放到后台做）
    @objc func connectExpanded() {
        guard let device = expandedDevice else { return }
        let connect = !device.connected
        showStatus(connect ? "正在连接…" : "正在断开…", error: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = connect ? device.device.openConnection() : device.device.closeConnection()
            DispatchQueue.main.async {
                guard let self else { return }
                if result != 0 {
                    self.showStatus("没能\(connect ? "连接" : "断开")（设备没开或不在附近？）", error: true)
                } else {
                    self.expanded = nil
                    self.changed()
                }
            }
        }
    }

    /// 忘记（取消配对）：系统设置里"忘记此设备"用的方法，不公开，先问它有没有
    @objc func forgetExpanded() {
        guard let device = expandedDevice else { return }
        let remove = NSSelectorFromString("remove")
        guard device.device.responds(to: remove) else {
            showStatus("这个系统版本不能在这里忘记设备，去系统设置里忘记", error: true)
            return
        }
        device.device.perform(remove)
        expanded = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.changed() }
    }
}

@main
enum BluetoothApp {
    static func main() {
        runPanelApp(anchor: "\(stateDir)/bluetooth-anchor", make: {
            let panel = BluetoothPanel()
            panel.start()
            return panel
        }, onHangup: { ($0 as? BluetoothPanel)?.pushBar(force: true) })
    }
}

