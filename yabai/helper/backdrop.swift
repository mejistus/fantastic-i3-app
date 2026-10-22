// SketchyBar 顶栏的底板（aero-helper bar-backdrop，由 ../../sketchybar/sketchybarrc 启动）
//
// 原生菜单栏的"磨砂"其实是壁纸：只取壁纸最上面菜单栏那么高的一条，横着用很大的半径模糊，再调色。身后的窗口
// （包括动态壁纸 App 铺在桌面上的窗口）不会透出来，只看系统壁纸。这里照着做：每块屏顶上放一条和栏一样大的窗口，
// 贴上这样算出来的图（见 wallpaperStrip，参数是换了二十多张纯色、渐变测试壁纸，和截下来的原生菜单栏逐个比出来的）。
// 读不到壁纸（动态壁纸等）时退回系统的磨砂材质。
// 系统按这一条的亮度给每块屏的菜单栏选浅色（黑字）或深色（白字），调色也不一样。选了哪个从状态栏窗口的外观读
// （见 checkLook），记在 defaults 的 fantastic-i3.sketchybar look 里，变了就重新加载 SketchyBar：colors.sh 按它给栏上的
// 文字、图标换色。SketchyBar 的颜色所有屏都一样，所以浅 / 深跟主屏走，别的屏的底板也按主屏的浅 / 深来算。
// SketchyBar 自己的 blur_radius 用的私有接口在 macOS 15 上对它的窗口不起作用，所以不用它。
//
// 系统菜单栏总是常显、占着顶上那一截（窗口和桌面图标都排在它下面，两种模式下布局一样），栏和底板盖在它上面：
// SketchyBar 的栏 topmost=on 是层级 25，和菜单栏右边的状态图标一样（菜单栏本身 24）。底板也放 25，排在 SketchyBar
// 整条栏的窗口紧后面：在栏后、状态图标前，挡住原生菜单栏的内容（见 orderBelowBar）。弹出的菜单、控制中心（101）在它们之上。PowerPoint 放映这类盖满整块屏的窗口出现时两者降到它下面，见 checkCovered。
// 不接收鼠标。
// 每条只放在自己那块屏的普通桌面上，不放在原生全屏的桌面上（SketchyBar 在那上面也不画栏），见 placeOnDesktops。
// 点开的面板（SketchyBar 的 popup）后面也垫一块：系统菜单的材质，和原生菜单栏里点开的面板一样，见 syncPanels。
// 每 3 秒问一次 SketchyBar 栏的高度和是否隐藏，顺便看壁纸换没换（切换桌面时也看，每个桌面可以有不同的壁纸）。
// 问不到时看 SketchyBar 的进程还在不在，不在了才退出：刚启动时它往往还在执行 sketchybarrc，睡眠唤醒后也要重建栏，
// 这些时候都问不到（之前连着问不到 3 次就退出，唤醒后底板就没了）。
// 换壁纸、换屏时窗口留着重用，只换位置和图（不闪）；问 SketchyBar、读壁纸、模糊都在后台做，不卡主线程。

import AppKit
import CoreImage

// 某块屏现在显示的桌面和它的类型（4 = 原生全屏），SketchyBar 也是这么判断的
@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> UInt64
@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: Int32, _ space: UInt64) -> Int32
// 各块屏上有哪些桌面（每块屏一项，"Spaces" 里 type 0 是普通桌面，4 是原生全屏），以及把窗口放到哪些桌面上
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

final class BarBackdrop {
    let sketchybar = "/opt/homebrew/bin/sketchybar"
    let yabai = "/opt/homebrew/bin/yabai"
    let work = DispatchQueue(label: "bar-backdrop", qos: .utility)
    var windows: [CGDirectDisplayID: NSWindow] = [:]   // 每块屏一条
    var height: CGFloat = 0
    var hidden = false
    var wallpapers = ""   // 各屏的位置、壁纸路径和修改时间；变了就重画
    var generation = 0    // 第几次重画：后台算得慢的旧图不要
    var lowered = false   // 有窗口盖满了某块屏，栏和底板降到了普通窗口下面（见 checkCovered）
    var level: NSWindow.Level { NSWindow.Level(rawValue: lowered ? -21 : 25) }   // 降下去时在栏（topmost=off，-20）下面
    var wakeGuardUntil = Date.distantPast   // 刚睡醒的这几秒屏幕状态还乱着，别跟着降栏（见 checkCovered）
    var wokeAt = Date.distantPast           // 上次处理唤醒的时间：系统会连发好几个唤醒通知，只处理一次
    var signalSource: DispatchSourceSignal?
    var panelSignal: DispatchSourceSignal?
    var glass: [Int: NSWindow] = [:]   // SketchyBar 面板的背景窗口号 → 垫在它后面的材质窗口
    var panelTimer: Timer?
    let panelRadius: CGFloat = 12      // 和 sketchybarrc 里 popup.background.corner_radius 一样
    let panelInset: CGFloat = 8        // 材质比面板上下各多出这么多：面板的上下留白（SketchyBar 的面板第一行贴顶、最后一行贴底）。
                                       // sketchybarrc 的 popup.y_offset 也多加了这么多，离栏的距离不变
    // 碰顶让开（见 checkPeek）
    let peekDwell = 0.7                // 鼠标顶在屏幕上边缘、基本不动这么多秒，栏让开
    let peekReturn = 0.3               // 让开后鼠标离开菜单栏那一截这么多秒（菜单也都关了），栏回来
    let peekSlack: CGFloat = 8         // 顶在边上横着挪超过这么多点就重新计时：顺着上边缘滑过去点栏上的某一项不算
    let peekMarker = "/tmp/yabai-aero-\(NSUserName())/bar-peek"   // 栏是这里让开的（aero bar-peek）；⌥⇧↩ 换过栏会删掉它
    var edge: (x: CGFloat, since: Date)?   // 鼠标从哪儿、什么时候开始顶在上边缘
    var awaySince: Date?               // 让开后鼠标从什么时候起不在菜单栏那一截
    var peeking = false
    var lastMenuCheck = Date.distantPast
    var panelWatchUntil = Date.distantPast   // 收到 SIGUSR2 后这段时间里一直找面板（它可能出来得晚）
    let wantedHidden = "/tmp/yabai-aero-\(NSUserName())/bar-hidden"   // aero show_bar / hide_bar 写的 on / off
    var hiddenSetAt = Date.distantPast       // 照 aero 写的藏 / 放出的时候：之后半秒内问到的不算（可能是 SketchyBar 还没跟上的旧状态）
    let prefs = UserDefaults(suiteName: "fantastic-i3.sketchybar")
    lazy var light = prefs?.string(forKey: "look") == "light"   // 栏现在是浅色（黑字）还是深色（白字），见 checkLook
    var lookProbe: NSStatusItem?   // 宽度为 0 的状态栏项：看不见，只用来读系统给每块屏的菜单栏选的外观
    var pendingLook: (light: Bool, since: Date)?   // 系统菜单栏换了浅 / 深，还没持续够久（见 checkLook）
    var newestWallpaper: [CGDirectDisplayID: (url: URL, modified: Date)] = [:]   // 每块屏最近用的、文件最新的壁纸
    var staleDisplays: Set<CGDirectDisplayID> = []   // 这些屏现在的桌面上系统存的壁纸过时了（见 wallpaper(for:)）

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // 不出现在程序坞和 ⌘⇥ 里，yabai 也不管它
        try? FileManager.default.removeItem(atPath: wantedHidden)   // 上次留下的
        lookProbe = NSStatusBar.system.statusItem(withLength: 0)
        sync()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.placeOnDesktops()   // 新加的桌面
            self?.checkWallpaper()
        }
        // 睡醒后 SketchyBar 会重画栏、屏可能刚回来：底板的前后顺序、系统菜单栏的透明度都可能对不上（见 woke）
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.woke()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.sync() }
        // 每秒看一次有没有盖满整块屏的窗口。查一次完整的窗口列表要几毫秒（窗口多时更多，窗口服务器那边也要干活），
        // 以前和面板一起每 0.2 秒查两次，这个进程常年占 20% 的 CPU
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkCovered() }.tolerance = 0.2
        // 鼠标位置每 0.1 秒看一次（只读一下坐标，不查窗口列表）
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkPeek() }.tolerance = 0.03
        // 面板不定时查：plugins/hover.sh 打开 / 收起面板后发 SIGUSR2，马上垫上材质。面板出现可能晚一些（忙的时候上百毫秒），
        // 所以之后 1 秒内每 1/30 秒看一次；面板开着时一直这样跟，收起后就停
        signal(SIGUSR2, SIG_IGN)
        let panels = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        panels.setEventHandler { [weak self] in
            self?.panelWatchUntil = Date().addingTimeInterval(1)
            self?.syncPanels()
        }
        panels.resume()
        panelSignal = panels
        // aero 换栏（⌥⇧↩）时把要的状态写进 $STATE/bar-hidden 再发 SIGUSR1：整个换栏由这里来做（switchBar）。
        // 没写状态就只是回头问一下 SketchyBar
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard let wanted = self.takeWantedHidden() else { self.sync(); return }
            self.switchBar(hidden: wanted)
        }
        source.resume()
        signalSource = source
        app.run()
    }

    /// 按 SketchyBar 现在的栏高和是否隐藏更新底板（在后台问，问完回主线程）
    func sync() {
        work.async { [weak self] in
            guard let self else { return }
            let bar = self.queryBar()
            let running = bar != nil || sketchybarRunning()
            DispatchQueue.main.async { self.apply(bar, running: running) }
        }
    }

    func apply(_ bar: [String: Any]?, running: Bool) {
        guard let bar else {
            if !running {
                logLine("bar-backdrop 退出：SketchyBar 不在了")
                exit(0)
            }
            if windows.isEmpty { height = 24; rebuild() }   // 先按 24 高建出来
            return
        }
        if ((bar["topmost"] as? String) == "off") != lowered { setTopmost() }   // SketchyBar 重载过（又成了 on）
        let newHeight = CGFloat((bar["height"] as? NSNumber)?.doubleValue ?? 24)
        let newHidden = (bar["hidden"] as? String) == "on" || (bar["position"] as? String) == "bottom"
        if newHeight != height || windows.isEmpty {
            height = newHeight
            hidden = newHidden
            rebuild()
        } else {
            // 藏起来只是变透明，窗口和图都留着：放出来时马上就是原样，不用重新建、等模糊图算好
            if newHidden != hidden && Date().timeIntervalSince(hiddenSetAt) > 0.5 {
                hidden = newHidden
                for window in windows.values { window.alphaValue = hidden ? 0 : 1 }
            }
            placeOnDesktops()
            checkWallpaper()
            checkLook()
        }
        orderBelowBar()
    }

    /// 系统给主屏的菜单栏选了浅色还是深色：看状态栏项在主屏菜单栏里的那个窗口的外观（VibrantLight / VibrantDark），
    /// 换壁纸后系统会跟着改。和记下的不一样就记下来、按新的重画底板，再重新加载 SketchyBar（栏上的文字、图标换色；
    /// 重新加载会重启这个进程，新的读到的记录和系统一致，不会再加载）。
    /// 两种情况不跟：主屏现在的桌面上系统存的壁纸过时了（系统菜单栏是照那张旧的选的，底板用的是最新的，见 wallpaper(for:)）；
    /// 变了还没持续够 2.5 秒（隔 3 秒的 sync 连着两次都这样才换）。不然切到很久没去的桌面时，系统菜单栏照旧壁纸先变深、
    /// 动态壁纸 App 一两秒后把壁纸设好又变回浅，栏跟着重新加载两次，闪两下
    func checkLook() {
        guard !hidden, fullscreenDisplays().isEmpty, let main = NSScreen.screens.first, let mainID = displayID(main),
              !staleDisplays.contains(mainID),
              let window = NSApp.windows.first(where: { window in
                  window.className == "NSStatusBarWindow" && abs(window.frame.maxY - main.frame.maxY) < 1
                      && window.screen.flatMap(displayID) == mainID
              }) else { pendingLook = nil; return }
        let isLight = window.effectiveAppearance.bestMatch(from: [.vibrantLight, .vibrantDark]) == .vibrantLight
        guard isLight != light else { pendingLook = nil; return }
        guard let pending = pendingLook, pending.light == isLight, Date().timeIntervalSince(pending.since) >= 2.5 else {
            if pendingLook?.light != isLight { pendingLook = (isLight, Date()) }
            return
        }
        pendingLook = nil
        light = isLight
        prefs?.set(isLight ? "light" : "dark", forKey: "look")
        logLine("顶栏换成\(isLight ? "浅色（黑字）" : "深色（白字）")：跟着主屏的系统菜单栏")
        rebuild()
        work.async { [weak self] in self?.runTool(self?.sketchybar ?? "", ["--reload"]) }
    }

    /// aero 写的要藏还是要出来（两秒内写的才算，读完就删）
    func takeWantedHidden() -> Bool? {
        let url = URL(fileURLWithPath: wantedHidden)
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard Date().timeIntervalSince(date) < 2 else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// 马上藏起 / 放出底板（只改透明度，窗口和图都留着）。放出来后等栏的窗口回到屏上再排到它后面
    func setHidden(_ value: Bool) {
        hidden = value
        hiddenSetAt = Date()
        for window in windows.values { window.alphaValue = value ? 0 : 1 }
        CATransaction.flush()   // 马上交给窗口服务器，不等这一轮主循环结束（换栏时后面还要等 yabai 的命令）
        if !value {
            for delay in [0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.orderBelowBar() }
            }
        }
    }

    func queryBar() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = ["--query", "bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // 睡醒后 SketchyBar 可能一时不答（以前一直等下去，底板就再也不问、不再排前后顺序了）：最多等 2 秒
        for _ in 0..<200 where process.isRunning { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func wallpaperSignature() -> String {
        NSScreen.screens.map { screen in
            let url = wallpaper(for: screen)
            let modified = (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(screen.frame) \(url?.path ?? "-") \(modified?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
    }

    /// 这块屏现在照哪张壁纸算底板。系统的壁纸每个桌面各存一份。动态壁纸 App（比如"我的壁纸"）在桌面层铺一个整屏的窗口
    /// 放自己的画面，再把同一张静态图设成系统壁纸（原生菜单栏只照系统壁纸调色），但只在切到某个桌面之后才设：
    /// 很久没去的桌面上存的还是以前的壁纸，切过去时底板先是旧壁纸的颜色，一两秒后才变过来。
    /// 所以有这种 App 的窗口盖着这块屏、现在的桌面上存的壁纸文件又比这块屏最近用的那张旧时，接着用最近那张
    func wallpaper(for screen: NSScreen) -> URL? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let display = displayID(screen) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let newest = newestWallpaper[display], newest.url != url, newest.modified > modified, liveWallpaperCovers(display) {
            staleDisplays.insert(display)
            return newest.url
        }
        staleDisplays.remove(display)
        newestWallpaper[display] = (url, modified)
        return url
    }

    /// 有没有不是系统自带的程序在这块屏的桌面层（比普通窗口低得多的那几层）铺了一个盖满整块屏的窗口：动态壁纸 App
    func liveWallpaperCovers(_ display: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(display)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer < -1_000_000_000,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary), frame.contains(bounds) else { return false }
            return !(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "com.apple.").hasPrefix("com.apple.")
        }
    }

    /// 全屏时不看：壁纸反正看不到，系统报的也不一定是桌面上那张，等退出全屏再说
    func checkWallpaper() {
        if !hidden, fullscreenDisplays().isEmpty, wallpaperSignature() != wallpapers { rebuild() }
    }

    func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 现在显示着原生全屏桌面的屏
    func fullscreenDisplays() -> Set<CGDirectDisplayID> {
        let cid = CGSMainConnectionID()
        return Set(NSScreen.screens.compactMap(displayID).filter { display in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let name = CFUUIDCreateString(nil, uuid) else { return false }
            return CGSSpaceGetType(cid, CGSManagedDisplayGetCurrentSpace(cid, name)) == 4
        })
    }

    /// PowerPoint 放映（还有不走原生全屏的视频、游戏）是普通桌面上一个层级 0、盖满整块屏的窗口（这时系统菜单栏也藏起来）。
    /// SketchyBar 只在原生全屏的桌面上藏栏，管不到这种；栏和底板又在所有窗口之上，就压在放映的画面上。
    /// 这时把两者都降到普通窗口下面，让它盖住：栏 topmost=off（层级 -20），底板 -21。
    /// 不直接藏：SketchyBar 没法只藏一块屏上的栏，降下去则只有被盖住的屏看不到。
    /// 每秒看一次窗口列表：放映开始时程序没有切换、桌面也没变，没有通知可等（最多晚 1 秒降下去）。
    /// 菜单栏常显时，最大化的窗口盖不到菜单栏那一截，不会算成盖满
    func checkCovered() {
        // 刚睡醒的几秒：登录窗口、clamshell 的切换都会让"有窗口盖满整屏"一时报得不准。
        // 这时降栏 / 升栏会让 SketchyBar 重建所有项（bar_manager_reset），栏上的项一个个消失再出现
        guard Date() >= wakeGuardUntil else { return }
        guard coveredByWindow() != lowered else { return }
        lowered.toggle()
        for window in windows.values { window.level = level }
        setTopmost()
        // 升回来时 SketchyBar 改 topmost 要一会儿：等它的栏回到 25 再排
        if !lowered { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.orderBelowBar() } }
    }

    /// 同一层级里谁在前看排序：把每条底板排到那块屏上 SketchyBar 整条栏（和屏一样宽、贴着顶边）的窗口紧后面。
    /// 栏藏起来（窗口挪到屏外）或降下去时不排
    func orderBelowBar() {
        guard !lowered, !hidden else { return }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for (display, window) in windows {
            let screen = CGDisplayBounds(display)
            let bar = info.first { entry in
                guard entry[kCGWindowOwnerName as String] as? String == "sketchybar",
                      let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
                return bounds.minX == screen.minX && bounds.minY == screen.minY && bounds.width == screen.width
            }
            if let number = bar?[kCGWindowNumber as String] as? Int { window.order(.below, relativeTo: number) }
        }
    }

    /// SketchyBar（2.24.1）设 topmost 时先按旧值重新排栏的位置、再记下新值（bar_manager_set_topmost 里 reset 在赋值前面），
    /// 而 topmost=off、系统菜单栏又常显时，它把栏排在菜单栏下面（往下一个菜单栏高，bar.c 的 bar_get_frame）。所以：
    ///   降下去（off）发一次：按旧的 on 排，栏还在顶上（没被盖住的别的屏上，栏也不会往下挪）；
    ///   升回来（on）发两次：第一次按旧的 off 排（往下错 24），第二次按 on 排回顶上。
    /// 以前只发一次，放映结束后栏上的各项一直往下错 24，压在窗口的标题栏上
    func setTopmost() {
        let arguments = lowered ? ["--bar", "topmost=off"] : ["--bar", "topmost=on", "--bar", "topmost=on"]
        work.async { [sketchybar] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sketchybar)
            process.arguments = arguments
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// 有没有哪块屏（原生全屏的除外）最上面的普通窗口正好盖满整块屏
    func coveredByWindow() -> Bool {
        let skip = fullscreenDisplays()
        let displays = NSScreen.screens.compactMap(displayID).filter { !skip.contains($0) }.map(CGDisplayBounds)
        guard !displays.isEmpty else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var done = Set<Int>()   // 已经找到最上面那个窗口的屏
        for window in info {    // 从前往后
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100 else { continue }   // 不算看不见的小窗口
            for (i, display) in displays.enumerated() where !done.contains(i) && bounds.intersects(display) {
                if bounds.contains(display) { return true }
                done.insert(i)
            }
            if done.count == displays.count { break }
        }
        return false
    }

    /// SketchyBar 的面板底色是全透明的（sketchybarrc 的 popup()），这里在每个打开的面板后面垫一块系统菜单的材质（.menu）：
    /// 磨砂、圆角、一圈细亮边和系统阴影，和原生菜单栏里点开的面板一样。面板是层级 101 的一组窗口（每行一个），
    /// 不被别的面板窗口包住的那个是背景，材质窗口和它一样大、排在它紧后面。
    /// 面板开着时每 1/30 秒跟一次（内容变了会变高、被 bar-stats 收起），关着时只等 SIGUSR2
    func syncPanels() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // 收起的面板 SketchyBar 不关窗口，只挪到屏外（-9999）：只算屏幕上的，不然一直当成开着，每秒 30 次跟个不停
        let screens = NSScreen.screens.compactMap(displayID).map(CGDisplayBounds)
        var rects: [(number: Int, rect: CGRect)] = []
        for entry in info where entry[kCGWindowOwnerName as String] as? String == "sketchybar"
                              && entry[kCGWindowLayer as String] as? Int == 101 {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  screens.contains(where: { $0.intersects(rect) }) else { continue }
            rects.append((number, rect))
        }
        let backgrounds = rects.filter { panel in
            !rects.contains { other in other.number != panel.number && other.rect != panel.rect && other.rect.contains(panel.rect) }
                && rects.contains { other in other.number != panel.number && panel.rect.contains(other.rect) }
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // 窗口列表是从前往后排的：材质窗口已经紧跟在面板背景后面就不用再排（每秒 30 次重排会让面板一顿一顿的）
        let order = info.compactMap { $0[kCGWindowNumber as String] as? Int }
        var keep = Set<Int>()
        for (number, rect) in backgrounds {
            keep.insert(number)
            let frame = NSRect(x: rect.minX, y: mainHeight - rect.maxY - panelInset,
                               width: rect.width, height: rect.height + 2 * panelInset)
            let window = glass[number] ?? makeGlass()
            if glass[number] == nil { glass[number] = window }
            if window.frame != frame {
                window.setFrame(frame, display: true)
                window.invalidateShadow()
            }
            if let at = order.firstIndex(of: number), at + 1 < order.count, order[at + 1] == window.windowNumber { continue }
            window.order(.below, relativeTo: number)
        }
        for (number, window) in glass where !keep.contains(number) {
            window.orderOut(nil)
            glass[number] = nil
        }
        if glass.isEmpty && Date() >= panelWatchUntil {
            panelTimer?.invalidate()
            panelTimer = nil
        } else if panelTimer == nil {
            panelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.syncPanels() }
        }
    }

    // MARK: - 碰顶让开

    /// 栏开着时，它下面的系统菜单栏（应用的菜单、没放进栏里的状态图标）点不到，以前只能 ⌥⇧↩ 换掉栏。
    /// 现在鼠标顶在屏幕上边缘、基本不动 peekDwell 秒，栏就让开（aero bar-peek on：栏藏起来，系统菜单栏露出来）；
    /// 鼠标离开菜单栏那一截 peekReturn 秒、点开的菜单也都关了，栏再回来（bar-peek off）。
    /// 栏被 ⌥⇧↩ 藏着、被放映降下去、有面板或菜单开着、这块屏是原生全屏时不让
    func checkPeek() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) }
        let fromTop = screen.map { $0.frame.maxY - mouse.y } ?? .infinity
        let now = Date()
        if peeking {
            // 让开期间 ⌥⇧↩ 换过栏（标记被删了）：不归这里管了
            guard FileManager.default.fileExists(atPath: peekMarker) else { peeking = false; return }
            if fromTop <= max(height, 24) + 6 { awaySince = nil; return }
            guard let since = awaySince else { awaySince = now; return }
            // 鼠标在点开的菜单里（菜单在菜单栏下面）就等它关上。查一次窗口列表要几毫秒，0.15 秒查一次
            guard now.timeIntervalSince(since) >= peekReturn, now.timeIntervalSince(lastMenuCheck) >= 0.15 else { return }
            lastMenuCheck = now
            if popupOpen(includingOurs: false) { return }
            peeking = false
            awaySince = nil
            try? FileManager.default.removeItem(atPath: peekMarker)
            switchBar(hidden: false)
            logLine("碰顶让开：栏回来")
            return
        }
        // 降下去了（放映等盖满整屏的窗口）也让：这时系统菜单栏是透明的，碰顶是把它找回来的唯一办法
        guard let screen, fromTop <= 2, !hidden, glass.isEmpty else { edge = nil; return }
        guard let start = edge, abs(mouse.x - start.x) <= peekSlack else { edge = (mouse.x, now); return }
        guard now.timeIntervalSince(start.since) >= peekDwell else { return }
        edge = nil
        if let display = displayID(screen), fullscreenDisplays().contains(display) { return }
        if popupOpen(includingOurs: true) { return }   //  菜单、Wi-Fi / 蓝牙面板这类开着
        peeking = true
        awaySince = nil
        FileManager.default.createFile(atPath: peekMarker, contents: nil)
        switchBar(hidden: true)
        logLine("碰顶让开：栏让开")
    }

    /// 屏幕上有没有开着的菜单或面板：系统菜单栏和状态图标点开的菜单、控制中心的面板都在 101 层（菜单的层级）。
    /// 只看 101：以前算的是 26–999 层，常驻的悬浮窗也算进去了——Dock 的跟踪窗口（27 层，铺满整块屏）、
    /// Vibe Island 的悬浮面板（27 层），碰顶让开就永远触发不了、触发了也回不来（2026-10-22）。
    /// 收起的 SketchyBar 面板挪在屏外（-9999），不在屏上就不算。
    /// includingOurs = false 时不算自己的（SketchyBar、aero-helper、Wi-Fi / 蓝牙面板）
    func popupOpen(includingOurs: Bool) -> Bool {
        let ours: Set<String> = ["sketchybar", "aero-helper", "fantastic-i3-wifi", "fantastic-i3-bluetooth"]
        let screens = NSScreen.screens.compactMap(displayID).map(CGDisplayBounds)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 101,
                  includingOurs || !ours.contains(window[kCGWindowOwnerName as String] as? String ?? ""),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return screens.contains { $0.intersects(bounds) }
        }
    }

    /// 换栏：SketchyBar 的栏、栏下面这条底板、系统菜单栏（yabai 的 menubar_opacity）三样一起换。
    /// 以前 aero 先发信号让这里改底板、自己再去改 SketchyBar，两边差几帧：中间空着一条磨砂，或者栏透明、没有磨砂。
    /// 现在都在这里按顺序做，SketchyBar 的命令一返回（它已经挪好窗口）就在同一个线程里改底板，前后只差一毫秒左右：
    ///   藏：系统菜单栏先看得见（这时还被盖着）→ 藏 SketchyBar → 撤底板
    ///   放：放出 SketchyBar → 垫上底板 → 系统菜单栏透明（这时已经被盖住）
    /// 在主线程上等这几个命令（一共二三十毫秒）
    func switchBar(hidden value: Bool) {
        if value {
            runTool(yabai, ["-m", "config", "menubar_opacity", "1.0"])
            runTool(sketchybar, ["--bar", "hidden=on"])
            setHidden(true)
        } else {
            runTool(sketchybar, ["--bar", "hidden=off"])
            setHidden(false)
            runTool(yabai, ["-m", "config", "menubar_opacity", "0.0"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sync() }   // 对一下栏高这些
    }

    /// 跑一个命令，等它结束。不用 Process.waitUntilExit：它隔一阵才看一次进程结束没有，要多等几十毫秒，
    /// SketchyBar 早换好了，底板还要等这么久才跟上
    func runTool(_ path: String, _ arguments: [String]) {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, nil, argv, environ) == 0 else { return }
        // 但最多等 2 秒：睡醒后 yabai / SketchyBar 有时会卡住一阵（yabai 的查询请求会一直不回），
        // 以前这里死等，把主线程（碰顶让开、换栏）也一起堵住了：栏没换过去，系统菜单栏也回不来
        var status: Int32 = 0
        for _ in 0..<200 {
            if waitpid(pid, &status, WNOHANG) == pid { return }
            usleep(10_000)
        }
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        logLine("bar-backdrop：\(path) 2 秒没退出，杀掉了")
    }

    /// 睡醒之后：SketchyBar 会重画栏，屏可能刚接回来（盖着的盖子打开了），底板的前后顺序和系统菜单栏的透明度
    /// 都可能和栏现在的样子对不上。醒后隔一会儿各做一次：问一次 SketchyBar、把底板排回栏后面、照栏的样子
    /// 把系统菜单栏设成该有的透明度（见 reassertMenuBar）。刚醒的几秒屏幕状态还乱，checkCovered 先不动栏
    func woke() {
        let now = Date()
        guard now.timeIntervalSince(wokeAt) > 3 else { return }   // 系统唤醒、屏幕唤醒会各发一个，只处理一次
        wokeAt = now
        wakeGuardUntil = now.addingTimeInterval(8)
        logLine("睡醒：重排底板、对一遍系统菜单栏")
        for delay in [1.5, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.sync()
                self.orderBelowBar()
                self.reassertMenuBar()
            }
        }
    }

    /// 栏没藏时系统菜单栏应该是透明的（栏盖着它），藏着（⌥⇧↩、碰顶让开）时应该露出来。
    /// 睡醒后会对不上：栏上的项不见了、系统菜单栏也是透明的，顶上只剩底板的磨砂。碰顶让开能救回来，
    /// 但要靠 switchBar 先改这个透明度，yabai 卡住的时候它也改不动，所以这里定期对一下
    func reassertMenuBar() {
        work.async { [weak self] in
            guard let self else { return }
            self.runTool(self.yabai, ["-m", "config", "menubar_opacity", self.hidden ? "1.0" : "0.0"])
        }
    }

    func makeGlass() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: 101)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(panelRadius)   // 圆角用遮罩：阴影也跟着圆角走
        let edge = NSView()   // 一圈细亮边（深色模式下原生菜单的边就是这样）
        edge.wantsLayer = true
        edge.layer?.cornerRadius = panelRadius
        edge.layer?.borderWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        edge.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        edge.autoresizingMask = [.width, .height]
        effect.addSubview(edge)
        window.contentView = effect
        edge.frame = effect.bounds
        return window
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

    /// 每条底板放到自己那块屏的所有普通桌面上，从别的桌面（原生全屏的）上拿掉。
    /// 不用"所有桌面都显示"（canJoinAllSpaces）：那样系统会把它也放到新建的全屏桌面上，进入全屏的一瞬间先画出来，
    /// 等收到切换桌面的通知再藏已经晚了约 90 ms，顶上闪一下磨砂（录屏逐帧看过）。新加的普通桌面在下次检查时补上
    func placeOnDesktops() {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return }
        for (display, window) in windows {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let name = CFUUIDCreateString(nil, uuid) as String? else { continue }
            // "显示器使用不同空间"关掉时只有一项，叫 Main
            let entry = displays.first { $0["Display Identifier"] as? String == name }
                ?? displays.first { $0["Display Identifier"] as? String == "Main" }
            let spaces = entry?["Spaces"] as? [[String: Any]] ?? []
            let desktops = Set(spaces.filter { $0["type"] as? Int == 0 }.compactMap { $0["id64"] as? Int })
            let ids = [window.windowNumber] as CFArray
            let current = Set(CGSCopySpacesForWindows(cid, 7, ids)?.takeRetainedValue() as? [Int] ?? [])
            let add = desktops.subtracting(current), remove = current.subtracting(desktops)
            if !add.isEmpty { CGSAddWindowsToSpaces(cid, ids, Array(add) as CFArray) }
            if !remove.isEmpty { CGSRemoveWindowsFromSpaces(cid, ids, Array(remove) as CFArray) }
        }
    }

    /// 每块屏一条：贴着屏幕顶边，宽同屏幕，高同栏。已有的窗口只挪位置，图在后台算好再换上
    func rebuild() {
        wallpapers = wallpaperSignature()
        generation += 1
        var screens: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens { if let display = displayID(screen) { screens[display] = screen } }
        for (display, window) in windows where height <= 0 || screens[display] == nil {
            window.orderOut(nil)
            windows[display] = nil
        }
        guard height > 0 else { return }
        var jobs: [(display: CGDirectDisplayID, wallpaper: URL?, size: CGSize, space: CGColorSpace)] = []
        for (display, screen) in screens {
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            if let window = windows[display] {
                window.setFrame(frame, display: false)
            } else {
                windows[display] = makeWindow(frame)
            }
            jobs.append((display, wallpaper(for: screen), screen.frame.size,
                         screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!))
        }
        placeOnDesktops()
        // 新建的窗口会排在层级 25 的最前面（makeWindow 的 orderFrontRegardless），压在 SketchyBar 整条栏上：
        // 屏刚接回来（打开盖子）时顶上就只剩一块磨砂。马上排到栏后面，不等下一次 sync
        orderBelowBar()
        let generation = self.generation, height = self.height, light = self.light
        work.async { [weak self] in
            guard let self else { return }
            let strips = jobs.map { job in
                (job.display, self.wallpaperStrip(job.wallpaper, screen: job.size, height: height, light: light, space: job.space))
            }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                for (display, strip) in strips {
                    if let window = self.windows[display] { self.fill(window, with: strip) }
                }
            }
        }
    }

    func makeWindow(_ frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.alphaValue = hidden ? 0 : 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.stationary, .ignoresCycle]   // 放在哪些桌面上由 placeOnDesktops 管
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = nil   // 图画好之前什么都不画
        window.orderFrontRegardless()
        return window
    }

    func fill(_ window: NSWindow, with strip: CGImage?) {
        let bounds = NSRect(origin: .zero, size: window.frame.size)
        if let strip {
            let view = NSView(frame: bounds)
            view.wantsLayer = true
            view.layer?.contents = strip
            view.layer?.contentsGravity = .resize   // 按 1/4 分辨率算的，拉伸回来（本来就糊，看不出）
            window.contentView = view
        } else {
            let glass = NSVisualEffectView(frame: bounds)
            glass.material = light ? .menu : .hudWindow   // 系统材质里和原生菜单栏最接近的
            glass.appearance = NSAppearance(named: light ? .vibrantLight : .vibrantDark)
            glass.blendingMode = .behindWindow
            glass.state = .active
            window.contentView = glass
        }
    }

    /// 原生菜单栏底下的样子（参数都是和原生的截图比出来的，见文件开头）：
    ///   1. 壁纸按"填充屏幕"铺好，只取最上面栏那么高的一条（再往下的壁纸不算：顶上一条白、下面全黑时原生的是纯白）
    ///   2. 横着高斯模糊，σ = 354 pt（左白右黑的壁纸上，原生的过渡正好是这个 σ 的高斯）；屏幕两头外面按镜像延伸
    ///      （两头颜色不一样的壁纸上比过：按边上的颜色延伸，两端会差到 20 个色阶）
    ///   3. 提饱和度（亮度按 Rec. 709 算），超出的截掉：深色 × 1.24，浅色 × 1.16
    ///   4. 深色：× 0.82；浅色：和白色按 33.5% 混合
    /// 全在这块屏自己的颜色空间里、带 gamma 的数值上算，出来的图也标成这个颜色空间，贴上去不再换算，和系统画的一样
    /// （换到 sRGB 或线性空间里提饱和度都差得多）。和原生比：深色在纯色测试壁纸上差 1 个色阶以内，浅色最多差 5 个
    /// （一个饱和度对不上所有颜色，取了两边都差不多的）；两张实际的壁纸（一浅一深）上平均差 2、最多差 6 个色阶。
    /// 按 1/4 分辨率算：模糊半径这么大，细节反正都没了。后台线程里调用
    func wallpaperStrip(_ url: URL?, screen: CGSize, height: CGFloat, light: Bool, space: CGColorSpace) -> CGImage? {
        guard let url, let image = CIImage(contentsOf: url),
              image.extent.width > 0, image.extent.height > 0 else { return nil }
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let k: CGFloat = 0.25
        // 取整：内置屏高 1050，× 0.25 = 262.5，边上那半个像素是半透明的，clampedToExtent 再把它往外铺开，
        // 糊出来整条都半透明（看着就是栏透明了）。所以尺寸取整，铺好的图也只留屏幕范围内整像素的部分
        let size = CGSize(width: floor(screen.width * k), height: floor(screen.height * k))
        // 铺满屏幕、居中裁掉多出来的部分（系统设置里的"填充屏幕"）
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width * scale) / 2,
                                               y: (size.height - image.extent.height * scale) / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
        let rows = max(1, (height * k).rounded())
        let strip = CGRect(x: 0, y: size.height - rows, width: size.width, height: rows)
        let saturation: CGFloat = light ? 1.16 : 1.24
        let (r, g, b) = (0.2126 * (1 - saturation), 0.7152 * (1 - saturation), 0.0722 * (1 - saturation))
        let gain: CGFloat = light ? 1 - 0.335 : 0.82, lift: CGFloat = light ? 0.335 : 0
        // 左右各接一份左右翻过来的（3σ 比屏幕窄，一份就够），再往外、上下按边上的延伸
        let band = placed.cropped(to: strip)
        let mirrored = band
            .composited(over: band.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
            .composited(over: band.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * size.width, ty: 0)))
        let result = mirrored.clampedToExtent()
            .applyingGaussianBlur(sigma: 354 * k)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r + saturation, y: g, z: b, w: 0),
                "inputGVector": CIVector(x: r, y: g + saturation, z: b, w: 0),
                "inputBVector": CIVector(x: r, y: g, z: b + saturation, w: 0)])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)])
            .cropped(to: strip)
        return context.createCGImage(result, from: strip, format: .RGBA8, colorSpace: space)
    }
}
