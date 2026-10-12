// SketchyBar 顶栏的底板（aero-helper bar-backdrop，由 ../../sketchybar/sketchybarrc 启动）
//
// 原生菜单栏的"磨砂"其实是壁纸：屏幕顶上那块壁纸用很大的半径（约 300 pt）模糊、略微压暗，所以壁纸亮的地方亮、
// 暗的地方几乎是黑的，中间平滑过渡，身后的窗口不会透出来。这里照着做：每块屏顶上放一条和栏一样大的窗口，
// 贴上这样算出来的图（参数和截下来的原生菜单栏逐段比对过）。读不到壁纸（动态壁纸等）时退回系统的磨砂材质。
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
    // 在 sRGB（带 gamma）里模糊和压暗，和比对时的算法一致
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    let work = DispatchQueue(label: "bar-backdrop", qos: .utility)
    var windows: [CGDirectDisplayID: NSWindow] = [:]   // 每块屏一条
    var height: CGFloat = 0
    var hidden = false
    var wallpapers = ""   // 各屏的位置、壁纸路径和修改时间；变了就重画
    var generation = 0    // 第几次重画：后台算得慢的旧图不要
    var lowered = false   // 有窗口盖满了某块屏，栏和底板降到了普通窗口下面（见 checkCovered）
    var level: NSWindow.Level { NSWindow.Level(rawValue: lowered ? -21 : 25) }   // 降下去时在栏（topmost=off，-20）下面
    var signalSource: DispatchSourceSignal?
    var panelSignal: DispatchSourceSignal?
    var glass: [Int: NSWindow] = [:]   // SketchyBar 面板的背景窗口号 → 垫在它后面的材质窗口
    var panelTimer: Timer?
    let panelRadius: CGFloat = 12      // 和 sketchybarrc 里 popup.background.corner_radius 一样

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // 不出现在程序坞和 ⌘⇥ 里，yabai 也不管它
        sync()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.placeOnDesktops()   // 新加的桌面
            self?.checkWallpaper()
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.sync() }
        // 每秒看一次有没有盖满整块屏的窗口。查一次完整的窗口列表要几毫秒（窗口多时更多，窗口服务器那边也要干活），
        // 以前和面板一起每 0.2 秒查两次，这个进程常年占 20% 的 CPU
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkCovered() }.tolerance = 0.2
        // 面板不定时查：plugins/hover.sh 打开 / 收起面板后发 SIGUSR2，马上垫上材质（面板出现可能晚几毫秒，再补看几次），
        // 之后面板开着时每 1/30 秒跟一次，收起后就停
        signal(SIGUSR2, SIG_IGN)
        let panels = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        panels.setEventHandler { [weak self] in
            for delay in [0, 0.02, 0.06, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.syncPanels() }
            }
        }
        panels.resume()
        panelSignal = panels
        // aero toggle-bar（⌥⇧↩）藏起 / 放出栏后发 SIGUSR1：马上跟着藏 / 出来，不等 3 秒一次的检查
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.sync() }
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
            if newHidden != hidden {
                hidden = newHidden
                for window in windows.values { window.alphaValue = hidden ? 0 : 1 }
            }
            placeOnDesktops()
            checkWallpaper()
        }
        orderBelowBar()
    }

    func queryBar() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = ["--query", "bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func wallpaperSignature() -> String {
        NSScreen.screens.map { screen in
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            let modified = (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(screen.frame) \(url?.path ?? "-") \(modified?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
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

    func setTopmost() {
        let value = lowered ? "off" : "on"
        work.async { [sketchybar] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sketchybar)
            process.arguments = ["--bar", "topmost=\(value)"]
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
        var rects: [(number: Int, rect: CGRect)] = []
        for entry in info where entry[kCGWindowOwnerName as String] as? String == "sketchybar"
                              && entry[kCGWindowLayer as String] as? Int == 101 {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
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
            let frame = NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
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
        if glass.isEmpty {
            panelTimer?.invalidate()
            panelTimer = nil
        } else if panelTimer == nil {
            panelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.syncPanels() }
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
        var jobs: [(display: CGDirectDisplayID, wallpaper: URL?, size: CGSize)] = []
        for (display, screen) in screens {
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            if let window = windows[display] {
                window.setFrame(frame, display: false)
            } else {
                windows[display] = makeWindow(frame)
            }
            jobs.append((display, NSWorkspace.shared.desktopImageURL(for: screen), screen.frame.size))
        }
        placeOnDesktops()
        let generation = self.generation, height = self.height
        work.async { [weak self] in
            guard let self else { return }
            let strips = jobs.map { ($0.display, self.wallpaperStrip($0.wallpaper, screen: $0.size, height: height)) }
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
            glass.material = .hudWindow   // 系统材质里和原生菜单栏最接近的
            glass.blendingMode = .behindWindow
            glass.state = .active
            window.contentView = glass
        }
    }

    /// 屏幕顶上那块壁纸模糊、压暗后的样子。按 1/4 分辨率算：模糊半径这么大，细节反正都没了。后台线程里调用
    func wallpaperStrip(_ url: URL?, screen: CGSize, height: CGFloat) -> CGImage? {
        guard let url, let image = CIImage(contentsOf: url),
              image.extent.width > 0, image.extent.height > 0 else { return nil }
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
        let strip = CGRect(x: 0, y: size.height - height * k, width: size.width, height: height * k)
        let darken = CIVector(x: -10 / 255, y: -10 / 255, z: -10 / 255, w: 0)
        let blurred = placed.clampedToExtent()
            .applyingGaussianBlur(sigma: 300 * k)
            .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": darken])
            .cropped(to: strip)
        return context.createCGImage(blurred, from: strip)
    }
}
