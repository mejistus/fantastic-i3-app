// SketchyBar 顶栏的数据（aero-helper bar-stats，由 ../../sketchybar/sketchybarrc 启动）
//
// 栏上：GPU、CPU、内存、磁盘的百分比，网速，输入法 —— 每 2 秒推一次（磁盘 30 秒一次）。
// 弹出详情：点栏上的某项时，plugins/hover.sh 打开它的面板，把项名写进
// /tmp/yabai-aero-$USER/bar-hover 并发 SIGUSR1，这里马上、之后每 2 秒算这一项的详情，
// 推给它弹出面板里的各行（<项>.<行>，在 sketchybarrc 里定义）。
// 只算正在看的那一项；进程排行这类比较贵的数据只在面板开着时算，而且最多 6 秒算一次。
// 面板开着时每 0.15 秒看一下鼠标位置，离开这一项和它的面板超过 0.3 秒就收起
// （SketchyBar 的 mouse.exited.global 在离开弹出面板时不触发，靠不住）。

import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import CoreWLAN
import IOKit
import SystemConfiguration

// MARK: - 格式

/// 内存按 1024 进制（和活动监视器一致）
func memoryText(_ bytes: Double) -> String {
    let gib = bytes / 1_073_741_824
    return gib >= 1 ? String(format: "%.1f GB", gib) : String(format: "%.0f MB", bytes / 1_048_576)
}

/// 磁盘按 1000 进制（和访达一致）
func diskText(_ bytes: Double) -> String {
    bytes >= 100e9 ? String(format: "%.0f GB", bytes / 1e9) : String(format: "%.1f GB", bytes / 1e9)
}

/// 速度：弹出面板里用的完整写法
func speedText(_ bytesPerSecond: Double) -> String {
    switch bytesPerSecond {
    case ..<1000: return "\(Int(bytesPerSecond)) B/s"
    case ..<1_000_000: return String(format: "%.1f KB/s", bytesPerSecond / 1000)
    default: return String(format: "%.2f MB/s", bytesPerSecond / 1_000_000)
    }
}

func durationText(minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
}

/// 超过 warn / alert 变黄 / 变红（颜色和 sketchybar/colors.sh 一致）
func levelColor(_ percent: Double, warn: Double = 60, alert: Double = 85) -> String {
    percent >= alert ? red : percent >= warn ? yellow : foreground
}

/// 弹出面板的颜色（两种主题都是彩色的，和 sketchybar/colors.sh 的调色板一致）
let green = "0xff98c379", yellow = "0xffe5c07b", red = "0xffe06c75", foreground = "0xffeaeaea"
let blue = "0xff61afef", lightBlue = "0xffa8d4f7", cyan = "0xff56b6c2", orange = "0xffd19a66"
let secondary = "0x99ffffff"   // 面板里的二级文字（sketchybar/colors.sh 的 POPUP_FG2）

/// SketchyBar 的进程还在不在。sketchybar 命令失败不一定是它退出了：重新加载、睡眠唤醒后重建栏的那几秒里也会失败，
/// 常驻的 bar-stats / bar-backdrop 只在进程真没了的时候才退出
func sketchybarRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "sketchybar"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return true }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// 记一行到 aero.log（和 aero log 同一个文件），常驻进程退出时留个原因
func logLine(_ text: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) \(text)\n"
    let path = "/tmp/yabai-aero-\(NSUserName())/aero.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}

// MARK: - CPU

struct CPUTicks {
    var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }
}

func cpuTicks() -> CPUTicks {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return CPUTicks() }
    return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                    idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
}

/// "Apple M2 · 8 核（4 性能 + 4 能效）"
func cpuTitle() -> String {
    let model = sysctlString("machdep.cpu.brand_string") ?? "CPU"
    let cores = sysctlInt("hw.ncpu") ?? 0
    if let performance = sysctlInt("hw.perflevel0.physicalcpu"), let efficiency = sysctlInt("hw.perflevel1.physicalcpu") {
        return "\(model) · \(cores) 核（\(performance) 性能 + \(efficiency) 能效）"
    }
    return "\(model) · \(cores) 核"
}

// MARK: - 各个核心

/// 一种核心：名字（性能核、能效核）和它们的逻辑 CPU 编号（host_processor_info 里的下标）
struct CoreGroup {
    let name: String
    let cpus: [Int]
}

/// 按核心类型分组，性能高的在前（面板里从左往右排）。
/// 类型看设备树 IODeviceTree:/cpus/cpuN 的 cluster-type："P" 性能核、"E" 能效核；以后有别的字母也单独分一组，排在两者之间。
/// 读不到时按 hw.perflevelN.logicalcpu 的个数分，编号小的性能低（M1–M4 都是能效核在前）；再不行就全算一组
func coreGroups(count: Int) -> [CoreGroup] {
    var types: [Int: String] = [:]
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    if cpus != 0 {
        var iterator: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
            var cpu = IOIteratorNext(iterator)
            while cpu != 0 {
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(cpu, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                if let id = property("logical-cpu-id") as? Int, let data = property("cluster-type") as? Data,
                   let type = String(bytes: data.prefix { $0 != 0 }, encoding: .ascii), !type.isEmpty {
                    types[id] = type
                }
                IOObjectRelease(cpu)
                cpu = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        IOObjectRelease(cpus)
    }
    if count > 0, Set(types.keys) == Set(0..<count) {
        let names = ["P": "性能核", "E": "能效核"]
        let rank = { (type: String) in type == "P" ? "0" : type == "E" ? "2" : "1" + type }
        return Dictionary(grouping: types.keys) { types[$0]! }
            .sorted { rank($0.key) < rank($1.key) }
            .map { CoreGroup(name: names[$0.key] ?? "\($0.key) 核", cpus: $0.value.sorted()) }
    }
    var groups: [CoreGroup] = [], next = 0
    for level in (0..<(sysctlInt("hw.nperflevels") ?? 0)).reversed() {
        guard let n = sysctlInt("hw.perflevel\(level).logicalcpu"), n > 0, next + n <= count else { break }
        let name = ["Performance": "性能核", "Efficiency": "能效核"][sysctlString("hw.perflevel\(level).name") ?? ""] ?? "核心"
        groups.insert(CoreGroup(name: name, cpus: Array(next..<next + n)), at: 0)
        next += n
    }
    return next == count && count > 0 ? groups : [CoreGroup(name: "核心", cpus: Array(0..<count))]
}

/// 每个逻辑 CPU 累计的 tick（下标就是 logical-cpu-id）
func coreTicks() -> [CPUTicks] {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
          let info else { return [] }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    return (0..<Int(cpuCount)).map { cpu in
        func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[Int(CPU_STATE_MAX) * cpu + Int(state)])) }
        return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
    }
}

// MARK: - 面板里的图

/// "0xAARRGGBB" → CGColor（alpha 给了就用给的）
func cgColor(_ hex: String, alpha: CGFloat? = nil) -> CGColor {
    let value = UInt32(hex.dropFirst(2), radix: 16) ?? 0xffff_ffff
    func channel(_ shift: UInt32) -> CGFloat { CGFloat((value >> shift) & 0xff) / 255 }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: alpha ?? channel(24))
}

/// 画一张 2 倍分辨率的 PNG 写到 path（单位 pt，原点在左下角；文字用 AppKit 画）。SketchyBar 把它当一行的背景图，缩成一半显示
func writePNG(_ path: String, width: CGFloat, height: CGFloat, _ draw: (CGContext) -> Void) {
    let scale: CGFloat = 2
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// 一段段不同颜色的文字（面板的字体，数字等宽）
func legendText(_ parts: [(String, String)], size: CGFloat = 11) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for (string, color) in parts {
        text.append(NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor(cgColor: cgColor(color)) ?? .white,
        ]))
    }
    return text
}

// MARK: - 进程

struct ProcessUsage {
    let name: String
    var cpu: Double      // %，可以超过 100（多核）
    var memory: Double   // 字节（常驻内存）
    var pids: [pid_t] = []
    var mine: [pid_t] = []   // 其中自己（当前用户）的，只有这些能退出
}

/// 按进程名合并（同名的多个进程加在一起）
func processUsage() -> [ProcessUsage] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-Aceo", "pid=,uid=,pcpu=,rss=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var byName: [String: ProcessUsage] = [:]
    let me = getuid()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5, let pid = pid_t(parts[0]), let uid = uid_t(parts[1]),
              let cpu = Double(parts[2]), let rss = Double(parts[3]) else { continue }
        let name = String(parts[4])
        var usage = byName[name] ?? ProcessUsage(name: name, cpu: 0, memory: 0)
        usage.cpu += cpu
        usage.memory += rss * 1024
        usage.pids.append(pid)
        if uid == me { usage.mine.append(pid) }
        byName[name] = usage
    }
    return Array(byName.values)
}

// MARK: - 内存

struct MemoryInfo {
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0
    var used: Double { app + wired + compressed }
}

/// 口径同活动监视器："已使用内存" = App 内存 + 联动内存 + 被压缩
func memoryInfo() -> MemoryInfo {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return MemoryInfo() }
    let page = Double(vm_kernel_page_size)
    let app = Double(stats.internal_page_count) - min(Double(stats.purgeable_count), Double(stats.internal_page_count))
    return MemoryInfo(app: app * page, wired: Double(stats.wire_count) * page,
                      compressed: Double(stats.compressor_page_count) * page,
                      cached: Double(stats.external_page_count + stats.purgeable_count) * page)
}

func swapUsage() -> (used: Double, total: Double) {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return (0, 0) }
    return (Double(swap.xsu_used), Double(swap.xsu_total))
}

/// 内存压力：1 正常、2 警告、4 严重
func memoryPressure() -> (text: String, color: String) {
    switch sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1 {
    case 4: return ("严重", red)
    case 2: return ("警告", yellow)
    default: return ("正常", green)
    }
}

// MARK: - GPU

struct GPUInfo {
    var model = "GPU", cores = 0
    var utilization = 0, renderer = 0, tiler = 0
    var inUse = 0.0, allocated = 0.0
}

/// IOAccelerator 的 PerformanceStatistics，不需要 root
func gpuInfo() -> GPUInfo? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var result: GPUInfo?
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let stats = property("PerformanceStatistics") as? [String: Any],
              let utilization = stats["Device Utilization %"] as? Int else { continue }
        var info = GPUInfo()
        info.model = property("model") as? String ?? "GPU"
        info.cores = property("gpu-core-count") as? Int ?? 0
        info.utilization = utilization
        info.renderer = stats["Renderer Utilization %"] as? Int ?? 0
        info.tiler = stats["Tiler Utilization %"] as? Int ?? 0
        info.inUse = Double(stats["In use system memory"] as? Int ?? 0)
        info.allocated = Double(stats["Alloc system memory"] as? Int ?? 0)
        result = info
    }
    return result
}

// MARK: - 磁盘

struct DiskInfo {
    var name = "磁盘", format = ""
    var total = 0.0, available = 0.0, free = 0.0   // available 含可清除空间（访达的口径），free 不含
    var used: Double { total - available }
    var purgeable: Double { max(0, available - free) }
}

func diskInfo() -> DiskInfo? {
    let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
                                     .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let total = values.volumeTotalCapacity, total > 0,
          let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
    return DiskInfo(name: values.volumeLocalizedName ?? "磁盘", format: values.volumeLocalizedFormatDescription ?? "",
                    total: Double(total), available: Double(available), free: Double(values.volumeAvailableCapacity ?? 0))
}

/// 所有块设备累计读写的字节数
func diskIOBytes() -> (read: Double, write: Double) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
    defer { IOObjectRelease(iterator) }
    var read = 0.0, write = 0.0
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
        read += Double(stats["Bytes (Read)"] as? Int ?? 0)
        write += Double(stats["Bytes (Write)"] as? Int ?? 0)
    }
    return (read, write)
}

// MARK: - 网络

/// 某个网卡累计收发的字节数（32 位计数，会回绕）
func interfaceBytes(_ name: String) -> (received: UInt32, sent: UInt32)? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = entry.pointee
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data,
              String(cString: ifa.ifa_name) == name else { continue }
        let counters = data.assumingMemoryBound(to: if_data.self).pointee
        return (counters.ifi_ibytes, counters.ifi_obytes)
    }
    return nil
}

enum InterfaceKind { case wifi, ethernet, vpn, other }

func interfaceKind(_ name: String) -> InterfaceKind {
    let wifi = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).contains {
        SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211 && SCNetworkInterfaceGetBSDName($0) as String? == name
    }
    if wifi { return .wifi }
    if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") { return .vpn }
    if name.hasPrefix("en") { return .ethernet }
    return .other
}

// MARK: - 电池

func batteryInfo() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return properties?.takeRetainedValue() as? [String: Any]
}

// MARK: - 声音

/// 默认输出设备的名字、音量（0-1，不支持调节时为 nil）、是否静音
func outputDevice() -> (name: String, volume: Float?, muted: Bool?)? {
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }

    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioObjectPropertyName
    let deviceName = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr
        ? (name?.takeRetainedValue() as String? ?? "输出设备") : "输出设备"

    address.mScope = kAudioDevicePropertyScopeOutput
    var volume: Float?
    address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    if AudioObjectHasProperty(device, &address) {
        var value = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { volume = value }
    }
    var muted: Bool?
    address.mSelector = kAudioDevicePropertyMute
    if AudioObjectHasProperty(device, &address) {
        var value = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { muted = value != 0 }
    }
    return (deviceName, volume, muted)
}

// MARK: - 输入法

/// 已启用的键盘输入法（名字、是否当前）
func inputSources() -> [(name: String, current: Bool)] {
    let current = inputSourceString(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    return selectableInputSources().map {
        (inputSourceString($0, kTISPropertyLocalizedName), inputSourceString($0, kTISPropertyInputSourceID) == current)
    }
}

/// 能切换到的键盘输入法，顺序和系统输入法菜单一样；输入法面板的第 i 行就是第 i 个
func selectableInputSources() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceIsSelectCapable as String: true,
                  kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
    return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
}

func inputSourceString(_ source: TISInputSource, _ key: CFString) -> String {
    guard let p = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

/// aero-helper input-select <i>：切到输入法面板第 i 行的输入法（plugins/hover.sh 点那一行时调）
func selectInputSource(_ index: Int) {
    let list = selectableInputSources()
    guard list.indices.contains(index) else { exit(1) }
    exit(TISSelectInputSource(list[index]) == noErr ? 0 : 1)
}

// MARK: - 日期

/// 农历："丙午马年 八月廿七"（闰月加"闰"）
func lunarDate(_ date: Date) -> String {
    let calendar = Calendar(identifier: .chinese)
    let c = calendar.dateComponents(in: TimeZone.current, from: date)
    guard let year = c.year, let month = c.month, let day = c.day else { return "" }
    let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥"), animals = Array("鼠牛虎兔龙蛇马羊猴鸡狗猪")
    let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    let digits = Array("一二三四五六七八九十")
    let dayText: String
    switch day {
    case 1...10: dayText = "初" + String(digits[day - 1])
    case 11...19: dayText = "十" + String(digits[day - 11])
    case 20: dayText = "二十"
    case 21...29: dayText = "廿" + String(digits[day - 21])
    default: dayText = "三十"
    }
    return "\(stems[(year - 1) % 10])\(branches[(year - 1) % 12])\(animals[(year - 1) % 12])年 "
        + "\(c.isLeapMonth == true ? "闰" : "")\(months[month - 1])月\(dayText)"
}

func formatted(_ date: Date, _ template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
}

// MARK: - 退出进程

/// 面板里点进程排行的一行：在鼠标处弹系统菜单，退出 / 强制退出这一行的进程（同名的几个一起，和活动监视器的"退出"一样）。
/// 应用先按正常的方式退出（和 ⌘Q 一样，没存的文稿会问），不是应用的发 SIGTERM；强制退出是 forceTerminate / SIGKILL。
/// 只动自己（当前用户）的进程；loginwindow（退出就注销）和 fantastic-i3 自己的进程不给退，菜单里写明原因
final class ProcessMenu: NSObject {
    var chosen: String?
    /// 退出会出事的：loginwindow 一退就注销；后面这些是栏和平铺本身（停掉用 fantastic-i3 stop）
    let protected = ["loginwindow": "退出它会注销当前用户",
                     "sketchybar": "fantastic-i3 的组件", "yabai": "fantastic-i3 的组件", "skhd": "fantastic-i3 的组件",
                     "aero-helper": "fantastic-i3 的组件", "fantastic-i3-wifi": "fantastic-i3 的组件",
                     "fantastic-i3-bluetooth": "fantastic-i3 的组件"]

    @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }

    /// file：bar-stats 写的 bar-top-<项>.json；index：点的是第几行
    func show(file: String, index: Int) {
        guard let data = FileManager.default.contents(atPath: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], list.indices.contains(index),
              let name = list[index]["name"] as? String else { return }
        let pids = list[index]["pids"] as? [Int] ?? [], mine = (list[index]["mine"] as? [Int] ?? []).map { pid_t($0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func info(_ title: String, bold: Bool = false) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold]) }
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ name: String) {
            let item = NSMenuItem(title: title, action: #selector(pick), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        info(name, bold: true)
        info(list[index]["summary"] as? String ?? "")
        menu.addItem(.separator())
        if let reason = protected[name] {
            info("不能在这里退出：\(reason)")
        } else if mine.isEmpty {
            info("系统进程，不能在这里退出")
        } else {
            if mine.count < pids.count { info("其中 \(pids.count - mine.count) 个是系统进程，不会退出") }
            action(mine.count > 1 ? "退出这 \(mine.count) 个进程" : "退出", "quit")
            action("强制退出", "force")
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        guard let chosen else { return }
        for pid in mine {
            if let app = NSRunningApplication(processIdentifier: pid),
               chosen == "force" ? app.forceTerminate() : app.terminate() { continue }
            kill(pid, chosen == "force" ? SIGKILL : SIGTERM)
        }
        print("\(chosen) \(name) \(mine.count)")
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

// MARK: - 推送

final class BarStats {
    let sketchybar = "/opt/homebrew/bin/sketchybar"
    let hoverFile = "/tmp/yabai-aero-\(NSUserName())/bar-hover"
    /// 面板里弹出的系统菜单（退出进程）开着时有这个文件（plugins/hover.sh 建、删）：鼠标在菜单上，不算离开面板
    let menuFile = "/tmp/yabai-aero-\(NSUserName())/bar-menu"
    /// CPU、GPU 最近的利用率（0–1），最多 historyLength 个点 = 弹出面板里曲线的宽度（sketchybarrc：POPUP_WIDTH - 28）。
    /// 内存面板的面积图也存在这里：mem.app、mem.wired、mem.compressed，各占物理内存的比例（0–1）。
    /// 重新加载 SketchyBar 时这个进程会被停掉、曲线也会清零：停掉前存进 historyFile，新进程启动时读回来补上
    var history: [String: [Double]] = ["cpu": [], "gpu": []]
    let memoryLayers = [("mem.compressed", orange), ("mem.wired", cyan), ("mem.app", green)]   // 面积图从下往上叠的顺序和颜色
    /// 面板里画的图的宽度（sketchybarrc：POPUP_WIDTH - 2 × POPUP_PAD）
    let chartWidth: CGFloat = 268
    let historyLength = 272
    // 存原始值（中间有一版存的是平滑过的，用的是别的文件名，不读）
    let historyFile = "/tmp/yabai-aero-\(NSUserName())/bar-history-raw.json"
    /// 面板里的曲线（9 分钟）画之前做前后对称的高斯平滑，σ = 3 个点（6 秒），见 smoothedHistory。栏上的小曲线画原始值
    let historySigma = 3.0
    var termSource: DispatchSourceSignal?
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    let store = SCDynamicStoreCreate(nil, "aero-helper" as CFString, nil, nil)
    var signalSource: DispatchSourceSignal?
    var ticks = 0

    // 开着的弹出面板：哪一项、面板加这一项占的区域（屏幕坐标，左上角为原点）、鼠标从什么时候起在外面
    var popup: (item: String, area: CGRect, outsideSince: Date?)?
    var popupTimer: Timer?
    var processCache: (time: Date, list: [ProcessUsage])?

    // 上一次采样，用来算这 2 秒的变化
    var lastCPU = cpuTicks()
    var lastCores = coreTicks()
    lazy var cores = coreGroups(count: lastCores.count)
    var coreUsage: [Double] = []   // 每个逻辑 CPU 这 2 秒的使用率（0–1）
    var imageTurn: [String: Int] = [:]
    var lastNet: (name: String, bytes: (received: UInt32, sent: UInt32), time: Date)?
    var lastDiskIO = (bytes: diskIOBytes(), time: Date())

    // 最近一次算出来的值，弹出面板直接用
    var cpu = (user: 0.0, system: 0.0, idle: 100.0)
    var net = (name: "", kind: InterfaceKind.other, down: 0.0, up: 0.0)
    var diskIO = (read: 0.0, write: 0.0)

    // 栏上的图标（Maple Mono NF 里的 Nerd Font 字形）
    let wifiIcon = "\u{F05A9}", ethernetIcon = "\u{F0200}", vpnIcon = "\u{F0582}", otherIcon = "\u{F059F}", offlineIcon = "\u{F05AA}"
    /// 栏上属于同一项的几块：网速拆成了 net（类型图标）、net.rx（↓）、net.tx（↑），箭头才能单独上色。
    /// 鼠标在这几块之间移动时面板不收
    let barParts = ["net": ["net.rx", "net.tx"]]

    func run(interval: TimeInterval) {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.inputChanged() }
        // hover.sh 打开弹出面板时发 SIGUSR1：马上推那一项的详情，开始盯鼠标
        signal(SIGUSR1, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signalSource?.setEventHandler { [weak self] in
            guard let self, let item = self.hovered() else { return }
            self.processCache = nil   // 刚打开面板、刚退出了进程：进程排行重新算
            self.send(self.details(item))
            self.watchPopup(item)
        }
        signalSource?.resume()
        // 被停掉（sketchybarrc 重新加载时 pkill）之前把曲线的历史存下来
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { [weak self] in self?.quit() }
        termSource?.resume()
        restoreHistory()

        sendStatic()
        inputChanged()
        // 第一次稍等一下再算：CPU 用的是两次采样的差，间隔太短数字会乱跳
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.run()
    }

    /// 调一次 sketchybar 命令；SketchyBar 不在了（命令失败）就退出
    func send(_ arguments: [String]) {
        guard !arguments.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { quitIfGone(); return }
        process.waitUntilExit()
        if process.terminationStatus != 0 { quitIfGone() }
    }

    /// 命令失败了：SketchyBar 真不在了才退出，只是一时忙（重新加载、睡眠唤醒）就跳过这一次
    func quitIfGone() {
        if !sketchybarRunning() {
            logLine("bar-stats 退出：SketchyBar 不在了")
            quit()
        }
    }

    func quit() -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: history) {
            try? data.write(to: URL(fileURLWithPath: historyFile))
        }
        exit(0)
    }

    /// 读回上一个进程存的历史（2 分钟以内的才算），补到栏上的曲线里（按时间顺序推，栏上的曲线只留最后那几个点）
    func restoreHistory() {
        let url = URL(fileURLWithPath: historyFile)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < 120,
              let data = try? Data(contentsOf: url), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]]
        else { return }
        var args: [String] = []
        for item in ["cpu", "gpu"] {
            let values = Array((saved[item] ?? []).suffix(historyLength))
            history[item] = values
            if !values.isEmpty { args += ["--push", item] + values.map { String(format: "%.3f", $0) } }
        }
        for (item, _) in memoryLayers { history[item] = Array((saved[item] ?? []).suffix(historyLength)) }
        send(args)
    }

    /// 记进历史，返回原样的值（栏上的小曲线推的就是它）
    @discardableResult
    func record(_ item: String, _ value: Double) -> Double {
        history[item, default: []].append(value)
        if history[item]!.count > historyLength { history[item]!.removeFirst(history[item]!.count - historyLength) }
        return value
    }

    /// 面板曲线的平滑：前后对称的高斯平均（σ = historySigma 个点）。2 秒一个点、一个点一个像素，原始值上下跳 10–20%，
    /// 画出来是一排三角波。整段历史每次都重推，所以可以前后都看，不像只往前看的平均那样让曲线落后几秒；
    /// 两头的点不够就按有的点重新归一，最新那头不会被拉低
    func smoothedHistory(_ values: [Double]) -> [Double] {
        let radius = Int(historySigma * 3)
        let weights = (0...radius).map { exp(-Double($0 * $0) / (2 * historySigma * historySigma)) }
        return values.indices.map { i in
            var sum = 0.0, total = 0.0
            for k in max(0, i - radius)...min(values.count - 1, i + radius) {
                sum += weights[abs(k - i)] * values[k]
                total += weights[abs(k - i)]
            }
            return sum / total
        }
    }

    /// 弹出面板里的曲线：SketchyBar 画弹出面板里的曲线时最新的点在最左边，和栏上（最新在右）反着。
    /// 所以面板开着时每次把整段历史重推一遍，顺序排成画出来最新在右：先推最旧的一个，再从最新推到第二旧的
    /// （曲线是个环形缓冲区，推满一圈后第 i 个推进去的点画在第 i 个位置，第 0 个在最左边，其余从第 width-1 个往右排）。
    /// 不够一圈的用 0 补在最旧那头
    func historyPush(_ item: String) -> [String] {
        let values = smoothedHistory(Array((history[item] ?? []).suffix(historyLength)))
        let full = [Double](repeating: 0, count: max(0, historyLength - values.count)) + values
        let order = [full[0]] + full[1...].reversed()
        return ["--push", "\(item).history"] + order.map { String(format: "%.3f", $0) }
    }

    func hovered() -> String? {
        let name = (try? String(contentsOfFile: hoverFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// 不会变的：各弹出面板的标题
    func sendStatic() {
        var args = ["--set", "cpu.title", "label=\(cpuTitle())",
                    "--set", "mem.title", "label=内存 · \(memoryText(memoryTotal))"]
        if let gpu = gpuInfo() {
            args += ["--set", "gpu.title", "label=\(gpu.model) · \(gpu.cores) 核 GPU"]
        }
        if let disk = diskInfo() {
            args += ["--set", "disk.title", "label=\(disk.name)\(disk.format.isEmpty ? "" : " · \(disk.format)")"]
        }
        send(args)
    }

    func inputChanged() {
        var args = ["--set", "input", "label=\(inputSourceLabel())"]
        if hovered() == "input" { args += details("input") }
        send(args)
    }

    func tick() {
        var args: [String] = []

        // CPU：栏上百分比和曲线，弹出面板里的曲线
        let ticksNow = cpuTicks()
        let total = Double(ticksNow.total &- lastCPU.total)
        if total > 0 {
            cpu = (Double(ticksNow.user &- lastCPU.user + ticksNow.nice &- lastCPU.nice) / total * 100,
                   Double(ticksNow.system &- lastCPU.system) / total * 100,
                   Double(ticksNow.idle &- lastCPU.idle) / total * 100)
        }
        lastCPU = ticksNow
        let cpuPercent = 100 - cpu.idle
        let cpuLine = record("cpu", cpuPercent / 100)
        args += ["--push", "cpu", String(format: "%.3f", cpuLine), "--set", "cpu", percentLabel(cpuPercent)]

        let coresNow = coreTicks()
        if coresNow.count == lastCores.count {
            coreUsage = zip(coresNow, lastCores).map { now, last in
                guard now.total > last.total, now.busy >= last.busy else { return 0 }
                return min(Double(now.busy - last.busy) / Double(now.total - last.total), 1)
            }
        }
        lastCores = coresNow

        let memory = memoryInfo()
        let memPercent = memory.used / memoryTotal * 100
        args += ["--set", "mem", percentLabel(memPercent)]
        record("mem.app", memory.app / memoryTotal)
        record("mem.wired", memory.wired / memoryTotal)
        record("mem.compressed", memory.compressed / memoryTotal)

        if let gpu = gpuInfo() {
            let gpuLine = record("gpu", Double(gpu.utilization) / 100)
            args += ["--set", "gpu", percentLabel(Double(gpu.utilization)),
                     "--push", "gpu", String(format: "%.3f", gpuLine)]
        }

        args += network()

        // 磁盘读写速度（弹出面板用），已用百分比 30 秒一次
        let io = diskIOBytes(), now = Date()
        let seconds = max(now.timeIntervalSince(lastDiskIO.time), 0.1)
        diskIO = (max(0, io.read - lastDiskIO.bytes.read) / seconds, max(0, io.write - lastDiskIO.bytes.write) / seconds)
        lastDiskIO = (io, now)
        if ticks % 15 == 0, let disk = diskInfo() {
            let used = disk.used / disk.total * 100
            args += ["--set", "disk", percentLabel(used)]
        }
        ticks += 1

        if let item = hovered() { args += details(item) }
        send(args)
    }

    /// 栏上的百分比。不补空格：SketchyBar 按字形轮廓算文字宽度，开头的空格不算宽度却照样画出来，
    /// 文字会往右挤进下一项。宽度由 sketchybarrc 里固定的 label.width 管（左对齐，数字贴着图标）。
    /// 满载写 "100" 不带 %：和 "99%" 一样宽，固定宽度只要容下两位数，平时图标和数字之间不留空
    func percentLabel(_ percent: Double) -> String {
        let value = Int(min(max(percent, 0), 100).rounded())
        return value == 100 ? "label=100" : "label=\(value)%"
    }

    /// 栏上的网络：主网卡（默认路由所在的）类型图标和上下行速度，分别推给 net / net.rx / net.tx
    func network() -> [String] {
        guard let store, let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String, let bytes = interfaceBytes(name) else {
            lastNet = nil
            net = ("", .other, 0, 0)
            return ["--set", "net", "icon=\(offlineIcon)", "--set", "net.rx", "icon.drawing=off", "label=离线",
                    "--set", "net.tx", "drawing=off"]
        }
        let now = Date()
        var down = 0.0, up = 0.0
        if let last = lastNet, last.name == name {
            let seconds = max(now.timeIntervalSince(last.time), 0.1)
            down = Double(bytes.received &- last.bytes.received) / seconds
            up = Double(bytes.sent &- last.bytes.sent) / seconds
        }
        lastNet = (name, bytes, now)
        let kind = interfaceKind(name)
        net = (name, kind, down, up)
        let icon = [InterfaceKind.wifi: wifiIcon, .ethernet: ethernetIcon, .vpn: vpnIcon][kind] ?? otherIcon
        return ["--set", "net", "icon=\(icon)", "--set", "net.rx", "icon.drawing=on", "label=\(rate(down))",
                "--set", "net.tx", "drawing=on", "label=\(rate(up))"]
    }

    /// 栏上的速度，最多 4 个字符："999B" "9.9K" "456K" "1.2M" "12M"（字符少，固定宽度就窄，数字短时空出来的也少）。
    /// 不补空格：宽度由 sketchybarrc 里固定的 label.width 管（左对齐）
    func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: return "\(Int(bytesPerSecond))B"
        case ..<9_950: return String(format: "%.1fK", bytesPerSecond / 1000)
        case ..<999_500: return "\(Int((bytesPerSecond / 1000).rounded()))K"
        case ..<9_950_000: return String(format: "%.1fM", bytesPerSecond / 1_000_000)
        default: return "\(Int((bytesPerSecond / 1_000_000).rounded()))M"
        }
    }

    // MARK: 弹出面板

    /// 进程列表：只在 CPU / 内存面板开着时用，最多 6 秒算一次
    func processes() -> [ProcessUsage] {
        if let cache = processCache, Date().timeIntervalSince(cache.time) < 6 { return cache.list }
        let list = processUsage()
        processCache = (Date(), list)
        return list
    }

    /// 读 sketchybar --query 的 JSON
    func query(_ name: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = ["--query", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 某一项（或面板里某一行）在屏幕上的位置；没画出来时是 nil
    /// 接了几块屏时栏上的项每块屏各有一个：给了 near 就挑离它最近的那个（和弹出面板在同一块屏上的）。
    /// 以前随便取一个，取到另一块屏上的，和面板合起来的区域横跨两块屏，鼠标总在里面，面板就一直不收
    func frame(_ name: String, near: CGRect? = nil) -> CGRect? {
        guard let rects = query(name)?["bounding_rects"] as? [String: Any] else { return nil }
        let all = rects.values.compactMap { value -> CGRect? in
            guard let rect = value as? [String: Any], let origin = rect["origin"] as? [Double], let size = rect["size"] as? [Double],
                  origin.count == 2, size.count == 2, origin[0] > -9000 else { return nil }
            return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
        }
        guard let near else { return all.first }
        let distance = { (r: CGRect) in hypot(r.midX - near.midX, r.midY - near.midY) }
        return all.min { distance($0) < distance($1) }
    }

    /// 面板打开后：量出这一项（连同 barParts 里的几块）加面板（第一行到最后一行）占的区域，开始盯鼠标。
    /// 面板还没画出来（量不到）就过一会儿再量，最多试 5 次
    func watchPopup(_ item: String, attempt: Int = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.hovered() == item else { return }
            // 面板只在一块屏上：先量面板（从两头找第一个画出来的行），再挑和它同一块屏上的那一项
            let rows = (self.query(item)?["popup"] as? [String: Any])?["items"] as? [String] ?? []
            // 用普通的循环：以前写成 rows.reversed().lazy.compactMap { … }.first，编译出来量不到的行会直接崩（2026-10-12 的崩溃报告）
            var top: CGRect?, bottom: CGRect?
            for row in rows { if let rect = self.frame(row) { top = rect; break } }
            if let top { for row in rows.reversed() { if let rect = self.frame(row, near: top) { bottom = rect; break } } }
            guard let top, let bottom, let bar = self.frame(item, near: top) else {
                if attempt < 5 { self.watchPopup(item, attempt: attempt + 1) }
                return
            }
            let parts = (self.barParts[item] ?? []).compactMap { self.frame($0, near: top) }
            let area = parts.reduce(bar.union(top).union(bottom)) { $0.union($1) }
            self.popup = (item, area.insetBy(dx: -10, dy: -10), nil)
            if self.popupTimer == nil {
                self.popupTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.checkPointer() }
            }
        }
    }

    /// 鼠标离开这一项和它的面板超过 0.3 秒就收起面板
    func checkPointer() {
        guard let current = popup, hovered() == current.item else {
            popup = nil
            popupTimer?.invalidate()
            popupTimer = nil
            return
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        if current.area.contains(location) || FileManager.default.fileExists(atPath: menuFile) {
            popup?.outsideSince = nil
        } else if let since = current.outsideSince {
            if Date().timeIntervalSince(since) >= 0.3 {
                send(["--set", current.item, "popup.drawing=off"])
                try? FileManager.default.removeItem(atPath: hoverFile)
                popup = nil
            }
        } else {
            popup?.outsideSince = Date()
        }
    }

    /// 面板里的图画到哪个文件：两个文件轮着用，路径变了 SketchyBar 才会重新读图
    func imagePath(_ name: String) -> String {
        let turn = (imageTurn[name] ?? 0) ^ 1
        imageTurn[name] = turn
        return "/tmp/yabai-aero-\(NSUserName())/\(name)-\(turn).png"
    }

    /// CPU 面板里每个核心的使用率：一核一根柱子，性能核在左（深蓝）、能效核在右（浅蓝），
    /// 下面一行写每种核有几个、平均用了多少。核多的机器柱子自动变窄
    func coresImage() -> String {
        let path = imagePath("cpu-cores")
        let groups = cores.filter { !$0.cpus.isEmpty }
        // 从下往上：底下留 2、图例 14、间隔 8、柱子 30、顶上留 4（和上一行的文字隔开）
        let width = chartWidth, bottom: CGFloat = 2, legendHeight: CGFloat = 14, gap: CGFloat = 8, barHeight: CGFloat = 30, top: CGFloat = 4
        let n = CGFloat(groups.reduce(0) { $0 + $1.cpus.count }), k = CGFloat(groups.count), groupGap: CGFloat = 12
        // 柱间距约为柱宽的 0.35，限制在 2–8 pt：核少时柱子不会隔得太开，核多时间距也看得见
        let spacing = min(8, max(2, 0.35 * (width - groupGap * (k - 1)) / (n + 0.35 * (n - k))))
        let bar = (width - groupGap * (k - 1) - spacing * (n - k)) / n
        let radius = min(4, bar / 2)
        func usage(_ cpu: Int) -> Double { cpu < coreUsage.count ? coreUsage[cpu] : 0 }
        func color(_ index: Int) -> CGColor {   // 第一组深、最后一组浅，中间的按比例
            let t = groups.count > 1 ? CGFloat(index) / CGFloat(groups.count - 1) : 0
            let from = cgColor(blue).components ?? [], to = cgColor(lightBlue).components ?? []
            guard from.count >= 3, to.count >= 3 else { return cgColor(blue) }
            return CGColor(srgbRed: from[0] + (to[0] - from[0]) * t, green: from[1] + (to[1] - from[1]) * t,
                           blue: from[2] + (to[2] - from[2]) * t, alpha: 1)
        }
        writePNG(path, width: width, height: bottom + legendHeight + gap + barHeight + top) { context in
            var x: CGFloat = 0
            for (index, group) in groups.enumerated() {
                for cpu in group.cpus {
                    // 边缘对齐到半个 pt（2 倍图上的整像素），柱子才清楚
                    let left = (x * 2).rounded() / 2, right = ((x + bar) * 2).rounded() / 2
                    let rect = CGRect(x: left, y: bottom + legendHeight + gap, width: right - left, height: barHeight)
                    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    context.addPath(shape)
                    context.setFillColor(cgColor("0x17ffffff"))
                    context.fillPath()
                    context.saveGState()
                    context.addPath(shape)
                    context.clip()
                    context.setFillColor(color(index))
                    context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * usage(cpu)))
                    context.restoreGState()
                    x += bar + spacing
                }
                x += groupGap - spacing
            }
            // 图例：● 性能核 ×4  23%。两组时一左一右；三组以上在整行里均匀排开。放不下就不写个数
            let dot: CGFloat = 6, dotGap: CGFloat = 5
            func legends(withCount: Bool) -> [NSAttributedString] {
                groups.map { group in
                    let average = group.cpus.map(usage).reduce(0, +) / Double(group.cpus.count) * 100
                    return legendText([(withCount ? "\(group.name) ×\(group.cpus.count)" : group.name, secondary),
                                       (String(format: "  %.0f%%", average), foreground)])
                }
            }
            func totalWidth(_ texts: [NSAttributedString]) -> CGFloat {
                texts.reduce(0) { $0 + dot + dotGap + $1.size().width } + 12 * CGFloat(texts.count - 1)
            }
            var texts = legends(withCount: true)
            if totalWidth(texts) > width { texts = legends(withCount: false) }
            let spread = groups.count > 1 ? max(12, (width - totalWidth(texts) + 12 * CGFloat(texts.count - 1)) / CGFloat(texts.count - 1)) : 0
            var left: CGFloat = 0
            for (index, text) in texts.enumerated() {
                context.setFillColor(color(index))
                context.fillEllipse(in: CGRect(x: left, y: bottom + (legendHeight - dot) / 2, width: dot, height: dot))
                text.draw(at: CGPoint(x: left + dot + dotGap, y: bottom + (legendHeight - text.size().height) / 2))
                left += dot + dotGap + text.size().width + spread
            }
        }
        return path
    }

    /// 内存面板的面积图：被压缩、联动内存、App 内存从下往上叠（和活动监视器"已使用内存"的三部分一样），
    /// 纵轴是物理内存的总量，最上面的边就是已使用的比例。和 CPU 的曲线一样约 9 分钟、同样平滑过，最新的在右边
    func memoryImage() -> String {
        let path = imagePath("mem-chart")
        let width = chartWidth, height: CGFloat = 40
        let series = memoryLayers.map { smoothedHistory(Array((history[$0.0] ?? []).suffix(historyLength))) }
        let count = series.map(\.count).min() ?? 0
        writePNG(path, width: width, height: height) { context in
            let frame = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(frame)
            context.setFillColor(cgColor("0x14ffffff"))
            context.fillPath()
            guard count > 1 else { return }
            context.addPath(frame)
            context.clip()
            let step = width / CGFloat(historyLength - 1)
            let xs = (0..<count).map { width - CGFloat(count - 1 - $0) * step }
            var below = [CGFloat](repeating: 0, count: count), edges: [[CGPoint]] = []
            for values in series {
                let top = (0..<count).map { below[$0] + CGFloat(values[values.count - count + $0]) * height }
                let area = CGMutablePath()
                area.addLines(between: (0..<count).map { CGPoint(x: xs[$0], y: top[$0]) }
                    + (0..<count).reversed().map { CGPoint(x: xs[$0], y: below[$0]) })
                area.closeSubpath()
                context.addPath(area)
                context.setFillColor(cgColor(memoryLayers[edges.count].1, alpha: 0.5))
                context.fillPath()
                edges.append((0..<count).map { CGPoint(x: xs[$0], y: top[$0]) })
                below = top
            }
            context.setLineWidth(1)
            context.setLineJoin(.round)
            for (edge, layer) in zip(edges, memoryLayers) {
                context.addLines(between: edge)
                context.setStrokeColor(cgColor(layer.1))
                context.strokePath()
            }
        }
        return path
    }

    /// 某一项弹出面板各行的内容（sketchybar --set 参数）
    func details(_ item: String) -> [String] {
        var args: [String] = []
        func row(_ name: String, _ value: String, color: String = foreground) {
            args += ["--set", "\(item).\(name)", "label=\(value)", "label.color=\(color)"]
        }
        func hide(_ name: String, _ hidden: Bool) {
            args += ["--set", "\(item).\(name)", "drawing=\(hidden ? "off" : "on")"]
        }
        /// 进程排行的五行：图标位置放进程名，值放用量。显示的这几个进程另外写进 bar-top-<项>.json，
        /// 点一行时 aero-helper process-menu 从这里读名字和进程号（ProcessMenu）
        func top(_ processes: [ProcessUsage], _ value: (ProcessUsage) -> String) {
            let shown = processes.prefix(5).map { process -> [String: Any] in
                ["name": process.name, "pids": process.pids, "mine": process.mine,
                 "summary": "\(process.pids.count) 个进程 · \(memoryText(process.memory)) · \(String(format: "%.1f%%", process.cpu)) CPU"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: shown) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/yabai-aero-\(NSUserName())/bar-top-\(item).json"))
            }
            for i in 0..<5 {
                if i < processes.count {
                    let name = processes[i].name.count > 20 ? String(processes[i].name.prefix(19)) + "…" : processes[i].name
                    args += ["--set", "\(item).top.\(i)", "drawing=on", "icon=\(name)", "label=\(value(processes[i]))"]
                } else {
                    hide("top.\(i)", true)
                }
            }
        }

        switch item {
        case "gpu":
            args += historyPush("gpu")
            guard let gpu = gpuInfo() else { break }
            row("util", "\(gpu.utilization)%", color: levelColor(Double(gpu.utilization)))
            row("render", "\(gpu.renderer)%")
            row("tiler", "\(gpu.tiler)%")
            row("mem", memoryText(gpu.inUse))
            row("alloc", memoryText(gpu.allocated))

        case "cpu":
            args += historyPush("cpu")
            row("user", String(format: "%.1f%%", cpu.user))
            row("system", String(format: "%.1f%%", cpu.system))
            row("idle", String(format: "%.1f%%", cpu.idle))
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            row("load", String(format: "%.2f  %.2f  %.2f", load[0], load[1], load[2]))
            row("uptime", durationText(minutes: Int(ProcessInfo.processInfo.systemUptime / 60)))
            args += ["--set", "cpu.cores", "background.image=\(coresImage())"]
            top(processes().sorted { $0.cpu > $1.cpu }) { String(format: "%.1f%%", $0.cpu) }

        case "mem":
            let memory = memoryInfo(), swap = swapUsage(), pressure = memoryPressure()
            let percent = memory.used / memoryTotal * 100
            args += ["--set", "mem.chart", "background.image=\(memoryImage())"]
            row("used", String(format: "%@（%.0f%%）", memoryText(memory.used), percent), color: levelColor(percent, warn: 75, alert: 90))
            // 这三项的数字用面积图里对应的颜色，当图例（和活动监视器 CPU 那页的"系统""用户"一样）
            row("app", memoryText(memory.app), color: green)
            row("wired", memoryText(memory.wired), color: cyan)
            row("compressed", memoryText(memory.compressed), color: orange)
            row("cached", memoryText(memory.cached))
            row("swap", swap.total > 0 ? "\(memoryText(swap.used)) / \(memoryText(swap.total))" : "未使用")
            row("pressure", pressure.text, color: pressure.color)
            top(processes().sorted { $0.memory > $1.memory }) { memoryText($0.memory) }

        case "disk":
            guard let disk = diskInfo() else { break }
            let percent = disk.used / disk.total * 100
            args += ["--set", "disk.bar", "slider.percentage=\(Int(percent))",
                     "slider.highlight_color=\(percent >= 90 ? red : percent >= 80 ? yellow : green)"]
            row("used", String(format: "%@（%.0f%%）", diskText(disk.used), percent), color: levelColor(percent, warn: 80, alert: 90))
            row("free", diskText(disk.available))
            row("purgeable", diskText(disk.purgeable))
            row("total", diskText(disk.total))
            row("read", speedText(diskIO.read))
            row("write", speedText(diskIO.write))

        case "net":
            let kindName = [InterfaceKind.wifi: "Wi-Fi", .ethernet: "以太网", .vpn: "VPN"][net.kind] ?? "网络"
            row("title", net.name.isEmpty ? "未连接" : "\(kindName) · \(net.name)")
            row("down", speedText(net.down))
            row("up", speedText(net.up))
            var ip = "—", router = "—"
            if let store, !net.name.isEmpty {
                if let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(net.name)/IPv4" as CFString) as? [String: Any],
                   let address = (v4["Addresses"] as? [String])?.first { ip = address }
                if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
                   let gateway = global["Router"] as? String { router = gateway }
            }
            row("ip", ip)
            row("router", router)
            // Wi-Fi：信号、速率、信道（无线网络名称需要定位权限，macOS 不给）
            if let wifi = CWWiFiClient.shared().interface(), wifi.rssiValue() != 0 {
                let rssi = wifi.rssiValue()
                let quality = rssi >= -55 ? ("极好", green) : rssi >= -67 ? ("良好", green) : rssi >= -75 ? ("一般", yellow) : ("较差", red)
                row("signal", "\(rssi) dBm（\(quality.0)）", color: quality.1)
                row("rate", String(format: "%.0f Mbps", wifi.transmitRate()))
                if let channel = wifi.wlanChannel() {
                    let band = [CWChannelBand.band2GHz: "2.4 GHz", .band5GHz: "5 GHz", .band6GHz: "6 GHz"][channel.channelBand] ?? ""
                    row("channel", "\(channel.channelNumber)\(band.isEmpty ? "" : "（\(band)）")")
                }
                for name in ["signal", "rate", "channel"] { hide(name, false) }
            } else {
                for name in ["signal", "rate", "channel"] { hide(name, true) }
            }

        case "input":
            let sources = inputSources()
            for i in 0..<5 {
                if i < sources.count {
                    args += ["--set", "input.src.\(i)", "drawing=on", "icon=\(sources[i].current ? "\u{F043E}" : "\u{F043D}")",
                             "icon.color=\(sources[i].current ? yellow : "0x66ffffff")", "label=\(sources[i].name)",
                             "label.color=\(sources[i].current ? foreground : "0x99ffffff")"]
                } else {
                    hide("src.\(i)", true)
                }
            }

        case "volume":
            guard let device = outputDevice() else { break }
            row("title", device.name)
            if let volume = device.volume {
                let percent = Int((volume * 100).rounded())
                args += ["--set", "volume.slider", "drawing=on", "slider.percentage=\(percent)"]
                row("level", "\(percent)%")
            } else {
                hide("slider", true)
                row("level", "这个设备不能调音量", color: "0x99ffffff")
            }
            row("muted", device.muted == true ? "是" : "否", color: device.muted == true ? yellow : foreground)

        case "battery":
            guard let battery = batteryInfo() else { break }
            let percent = battery["CurrentCapacity"] as? Int ?? 0
            let charging = battery["IsCharging"] as? Bool ?? false
            let external = battery["ExternalConnected"] as? Bool ?? false
            let full = battery["FullyCharged"] as? Bool ?? false
            let state = full ? "已充满" : charging ? "充电中" : external ? "已接电源，未充电" : "使用电池"
            row("title", "电池 · \(state)")
            let charge = percent < 30 ? red : percent < 80 ? yellow : green   // 80% 以上绿，30–80% 黄，30% 以下红
            args += ["--set", "battery.bar", "slider.percentage=\(percent)", "slider.highlight_color=\(charge)"]
            row("level", "\(percent)%", color: charge)
            let minutes = charging ? battery["AvgTimeToFull"] as? Int : external ? nil : battery["AvgTimeToEmpty"] as? Int
            row("time", minutes.map { $0 >= 65535 ? "计算中…" : charging ? "\(durationText(minutes: $0))后充满" : "还能用 \(durationText(minutes: $0))" }
                ?? (full ? "—" : "—"))
            let watts = (battery["AdapterDetails"] as? [String: Any])?["Watts"] as? Int
            row("power", external ? (watts.map { "\($0) W 电源适配器" } ?? "电源适配器") : "电池")
            if let design = battery["DesignCapacity"] as? Int, design > 0, let max = battery["AppleRawMaxCapacity"] as? Int {
                let health = Double(max) / Double(design) * 100
                row("health", String(format: "%.0f%%（%d / %d mAh）", health, max, design), color: health < 80 ? yellow : foreground)
            }
            row("cycles", "\(battery["CycleCount"] as? Int ?? 0) 次")
            if let temperature = battery["Temperature"] as? Int {
                row("temp", String(format: "%.1f °C", Double(temperature) / 100))
            }

        case "clock":
            let now = Date()
            let calendar = Calendar.current
            row("title", formatted(now, "yMMMMdEEEE"))
            row("lunar", lunarDate(now))
            row("week", "第 \(calendar.component(.weekOfYear, from: now)) 周 · 今年第 \(calendar.ordinality(of: .day, in: .year, for: now) ?? 0) 天")
            let offset = TimeZone.current.secondsFromGMT() / 3600
            row("zone", "\(formatted(now, "zzzz"))（UTC\(offset >= 0 ? "+" : "")\(offset)）")

        default:
            break
        }
        return args
    }
}
