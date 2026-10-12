// 顶栏的原生面板（BarPanels.app，由 ../../aero panel 编译、启动）：Wi-Fi（wifi.swift）和蓝牙（bluetooth.swift）。
// 不放在 SketchyBar 里：要搜索框、密码框；独立成 App：macOS 只把 Wi-Fi 名称给有定位权限的程序，读蓝牙设备要蓝牙权限，
// 这两个权限都只能给 App（第一次启动时系统各问一次，之后记住）。
//
// 常驻后台（不在程序坞里）：
//   SIGUSR1：读 $STATE/panel-anchor（"<wifi|bluetooth> <左> <上>"），在那里打开这个面板，开着就收起；别的面板收起
//   SIGUSR2：都收起（打开了 SketchyBar 的面板、 菜单）
//   SIGHUP： SketchyBar 重新加载过，把栏上的蓝牙图标再推一遍
// 点面板外面、按 Esc、切换桌面也收起。

import AppKit

// 信号先忽略掉（默认动作是退出），下面再接上：aero 可能在这个进程刚启动、还没接好时就发信号
for number in [SIGUSR1, SIGUSR2, SIGHUP] { signal(number, SIG_IGN) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wifiPanel = WiFiPanel()
let bluetoothPanel = BluetoothPanel()
let panels: [String: BarPanel] = ["wifi": wifiPanel, "bluetooth": bluetoothPanel]
wifiPanel.start()
bluetoothPanel.start()

var signalSources: [DispatchSourceSignal] = []
func onSignal(_ number: Int32, _ handler: @escaping () -> Void) {
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler(handler: handler)
    source.resume()
    signalSources.append(source)
}
onSignal(SIGUSR1) {
    let parts = (try? String(contentsOfFile: anchorFile, encoding: .utf8))?.split(whereSeparator: \.isWhitespace) ?? []
    guard parts.count == 3, let panel = panels[String(parts[0])],
          let left = Double(parts[1]), let top = Double(parts[2]) else { return }
    for other in panels.values where other !== panel { other.close() }
    panel.toggle(left: left, top: top)
}
onSignal(SIGUSR2) { panels.values.forEach { $0.close() } }
onSignal(SIGHUP) { bluetoothPanel.pushBar(force: true) }
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                  object: nil, queue: .main) { _ in panels.values.forEach { $0.close() } }
app.run()
