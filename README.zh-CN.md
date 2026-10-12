# fantastic-i3-macOS

[English](README.md) · 属于 [fantastic-i3](https://github.com/mejistus/fantastic-i3/blob/main/README.zh-CN.md)，那边是 Linux 上的 i3 配置

macOS 上 i3 风格的平铺桌面。[yabai](https://github.com/asmvik/yabai) 平铺窗口，[skhd](https://github.com/asmvik/skhd) 管快捷键，[SketchyBar](https://github.com/FelixKratz/SketchyBar) 代替菜单栏。有 17 个工作区：1 … 10 和 Z X C B N M T，每个对应一个 macOS 桌面。

[安装](#安装) · [快捷键](#快捷键) · [固定工作区](#固定工作区) · [顶栏](#顶栏) · [瞬间切换](#瞬间切换) · [排错](#排错) · [文件](#文件)

## 安装

只支持 Apple Silicon。一行：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mejistus/fantastic-i3-macOS/main/install.sh)"
```

已经克隆了仓库，就在里面运行 `bash install.sh`。脚本可以重复运行，它会：

1. 没有 Homebrew 就装上。会问开机密码，顺带装好 Xcode 命令行工具。
2. 用 curl 跑的，把仓库克隆到看不见的 `~/.local/share/fantastic-i3-macOS`。已经克隆了的放在哪里都行（比如 fantastic-i3 的子模块 `macos`）。
3. 逐个检查 yabai、skhd、SketchyBar、jq 和字体，没装的装上。
4. 把仓库里的 `yabai`、`skhd`、`sketchybar` 三个文件夹链接成 `~/.config/yabai`、`~/.config/skhd`、`~/.config/sketchybar`，原来的备份成 `.bak-日期`。配置和脚本之间都经由 `~/.config` 互相找，别处不建任何链接。
5. 关掉"根据最近的使用情况自动重新排列空间"。
6. 编译 aero-helper（窗口切换器、顶栏数据），启动各项服务。系统菜单栏设为常显，SketchyBar 盖在它上面。

然后列出还要手动做的事：

- 系统设置 → 隐私与安全性 → 辅助功能：打开 yabai 和 skhd，再运行一次脚本。
- 在调度中心里把桌面加到 17 个。

最后打印一张快捷键表，建议截图保存；`install.sh --keys` 可以再打印一次。

Wi-Fi、蓝牙面板第一次启动时，系统会问"fantastic-i3-wifi"能不能使用你的位置、"fantastic-i3-bluetooth"能不能使用蓝牙，两个都请点允许：macOS 只把 Wi-Fi 名称给有定位权限的程序，蓝牙面板要蓝牙权限才能列出你的设备。

## 快捷键

### 工作区

| 快捷键 | 作用 |
|---|---|
| <kbd>⌥1</kbd> … <kbd>⌥9</kbd> <kbd>⌥0</kbd> | 切到工作区 1 … 10 |
| <kbd>⌥Z</kbd> <kbd>⌥X</kbd> <kbd>⌥C</kbd> <kbd>⌥B</kbd> <kbd>⌥N</kbd> <kbd>⌥M</kbd> <kbd>⌥T</kbd> | 切到工作区 Z X C B N M T（桌面 11 … 17）。⌥T 要[脚本扩展](#瞬间切换)：macOS 只有切换到桌面 1 … 16 的快捷键 |
| <kbd>⌥</kbd> + <kbd>Caps Lock</kbd> | 也是工作区 10。Caps Lock 没改过、或改成了 🌐/fn 都能用 |
| <kbd>⌥⇧</kbd> + 上面的键 | 把窗口移到那个工作区，人也跟过去 |
| <kbd>⌃H</kbd> / <kbd>⌃L</kbd> | 上一个 / 下一个工作区：1 … 10，加上有窗口的字母工作区 |
| <kbd>⌥⇧⇥</kbd> | 把工作区挪到下一个显示器（要脚本扩展） |

### 窗口

| 快捷键 | 作用 |
|---|---|
| <kbd>⌥H</kbd> <kbd>⌥J</kbd> <kbd>⌥K</kbd> <kbd>⌥L</kbd> | 焦点移到左 / 下 / 上 / 右 |
| <kbd>⌥⇧H</kbd> <kbd>⌥⇧J</kbd> <kbd>⌥⇧K</kbd> <kbd>⌥⇧L</kbd> | 和那边的窗口交换 |
| <kbd>⌥</kbd> / <kbd>⌥⇧</kbd> + 方向键 | 同上，用方向键。系统里按词移动 / 选择的快捷键就被占掉了 |
| <kbd>⌥F</kbd> | 全屏 / 还原 |
| <kbd>⌥⇧F</kbd> | 平铺 ↔ 浮动 |
| <kbd>⌥-</kbd> / <kbd>⌥=</kbd> | 缩小 / 放大 |
| <kbd>⌥R</kbd> | 调大小模式：H J K L 或方向键调宽高，Esc 退出 |

### 切换和打开

| 快捷键 | 作用 |
|---|---|
| <kbd>⌥⇥</kbd> | 点一下：上一个应用；按住 ⌥：应用列表 |
| <kbd>⌘⇥</kbd> | 代替 macOS 的应用切换器，按窗口切换。点一下回到上一个窗口，按住 ⌘ 列出所有桌面的窗口 |
| <kbd>⌘Space</kbd> | 直接打开应用列表，代替 Spotlight。再按一次关掉 |
| <kbd>⌥D</kbd> | 把一个 Finder 窗口拿到当前工作区，没有就新开 |
| <kbd>⌥⇧D</kbd> | 在当前工作区新开一个 Finder 窗口，打开文稿 |
| <kbd>⌥G</kbd> | 工作区 1 的默认浏览器：那里有它的窗口就切过去，没有就新开 |
| <kbd>⌥⇧V</kbd> | 剪贴板历史：复制过的文字、图片、文件（最多 300 条，其中图片 40 张），新的在前，右边预览：复制的图片直接显示，复制的文件用系统"快速查看"显示（照片、PDF、视频、文稿都行），并标出大小和像素尺寸。打字搜索（拼音也行），回车粘贴到原来的应用，⌘回车只复制，⌘⌫ 删掉一条，⌘+ / ⌘- 缩放（会记住，⌘0 恢复默认）；再按一次 ⌥⇧V 关掉。密码管理器标成隐藏的内容不记。存在 `~/.config/fantastic-i3/clipboard/`，只有你自己能读 |
| <kbd>⌥O</kbd> | 框选一块屏幕，把里面的文字按行复制下来（系统自带的文字识别，不联网）。中英文、简繁，夹着日文、韩文也行：中、日、韩三种模型各认一遍再合起来 |
| <kbd>⌥I</kbd> | 框选一个公式，把它的 LaTeX 源码复制下来（SiliconFlow 的视觉大模型，模型、提示词和清理都和 Raycast 扩展 latex-ocr-queen 一样）。要 SiliconFlow 的 API Key，见下 |

框选完，屏幕下方会出现一个小提示条：识别时转圈，复制好了显示 ✓ 和内容开头，失败时显示 ✗ 和原因。⌥O 认不出 ⌘ ⌥ ⇧ ↩ ← 这类键盘和特殊符号，系统的文字识别不认识它们。

⌥I 用环境变量 `SILICONFLOW_API_TOKEN`（或 `SILICONFLOW_API_KEY`）里的 SiliconFlow API Key。skhd 启动的命令不经过你的 shell，所以 `capture` 从 `~/.zshrc` 里取出 export 它的那一行，只把这一行交给 zsh 求值。也可以存进钥匙串：`security add-generic-password -U -a "$USER" -s fantastic-i3-siliconflow -w`。Raycast 里如果也给 ⌥O / ⌥I 设了快捷键，记得在那边删掉。

两个列表里都直接打字搜索。按键不经过输入法，输入法保持原样。中文名用拼音搜，全拼或首字母都行（天氣：`tianqi` 或 `tq`）。↑ ↓ 或再按列表自己的键（⌥⇥ / ⌘⇥，加 ⇧ 往上）选择，回车或单击切换，Esc 关闭，⌘+ / ⌘- 调字号。

- **窗口列表**：所有窗口，按工作区排。开着但没有窗口的应用排在最后，选它就像点 Dock 图标。
- **应用列表**：启动台里的所有应用，一个应用一行。有窗口的在最前，按最近使用排，选中就去它最近用的窗口；然后是开着但没窗口的；最后是其余的，按名字排，选中没开的就打开它。

### 服务模式：先按 <kbd>⌃S</kbd>，再按

| 快捷键 | 作用 |
|---|---|
| <kbd>M</kbd> | 记住当前应用平铺还是浮动，以后它新开的窗口照办。平铺只管标准窗口，对话框照样浮动。存在 `~/.config/fantastic-i3/layouts` |
| <kbd>W</kbd> | 记住当前应用的工作区：以后新开的窗口去那里，人也跟过去。盖过[固定工作区](#固定工作区)。存在 `~/.config/fantastic-i3/workspaces` |
| <kbd>F</kbd> | 当前工作区的窗口全部平铺 ↔ 全部浮动 |
| <kbd>J</kbd> / <kbd>H</kbd> / <kbd>V</kbd> | 切换分割方向 / 下一个窗口开在右边 / 开在下面 |
| <kbd>R</kbd> | 调大小模式 |
| <kbd>Esc</kbd> | 重新加载配置，不重启 yabai，窗口不动 |

想忘掉某个应用：删掉文件里那一行，再按 ⌃S Esc。

### 其它

| 快捷键 | 作用 |
|---|---|
| <kbd>⌥⇧↩</kbd> | 临时藏起顶栏，露出下面的系统菜单栏（应用的菜单在那里）；再按一次放回来。重新登录或重新加载 SketchyBar 后回到[你选的那个](#顶栏) |

## 固定工作区

大多数应用的新窗口开在当前工作区。少数几个有固定的工作区：

| 应用 | 工作区 |
|---|---|
| Microsoft Edge | 1，平铺 |
| iTerm2、kitty、终端 | 5 |
| 微信 | 10 |
| 用 ⌃S W 记住的应用 | 记住的那个 |

- 这些应用没有窗口时被激活（比如从 Dock 打开），会先切到它的工作区，新窗口不会先在当前工作区闪一下。之后的新窗口也会带你过去。
- 在 ⌥⇥、⌘⇥ 或 ⌘Space 列表里选它们，也会先切到它们的工作区再打开。
- 从 Dock、通知或链接激活任何应用时，如果它在当前工作区没有窗口，就会带你去它最近用的窗口。macOS 设置里"切换应用时跳到它窗口所在的空间"那一项虽然关着，点一次 Dock 也就够了。

写死的这几条在 [`yabai/yabairc`](yabai/yabairc) 里。

## 顶栏

仿照 i3 polybar 样式的 SketchyBar 顶栏（One Dark，Maple Mono NF），和菜单栏一样高（24 pt），一样是毛玻璃，盖在常显的系统菜单栏上。顶栏开着时，用 yabai 的 `menubar_opacity` 把系统菜单栏（连同状态图标）设成看不见、点击穿过，所以不会从下面冒出来。菜单栏占着顶上那一截，所以不管顶栏开不开，窗口和桌面图标都排在它下面。要用应用的菜单（文件、编辑……），按 ⌥⇧↩ 把顶栏藏起来。

**左边**

-  菜单，就是真正的 macOS 菜单：关于本机、系统设置、App Store、睡眠、重新启动、关机、锁定屏幕、退出登录。重新启动、关机和退出登录会先确认。
- 工作区 1 … 10 和 Z … T，上面是各自的应用图标，点一下就切过去。空的字母工作区只在你待在那里时显示。
- skhd 模式（RESIZE / SERVICE），然后是当前应用和窗口标题。

**右边**

- 主题开关：彩色或黑白图标。警告色保持黄 / 红，面板保持彩色。
- GPU（Apple Silicon）和 CPU，各有曲线和百分比；然后是内存、磁盘（已用，算法和访达一样）。
- 蓝牙（关着时是灰的）、网速（上传在上、下载在下，小一号字）、输入法（中 / EN）、音量（滚轮调）、电池（80 % 以上绿、30 % 起黄、更低红），以及按系统语言显示的日期时间（10月7日 週三 13:55）。

点右边任一项打开详情面板，再点一次或移开就关掉。面板标题里的 ↗ 打开对应的应用或设置页。

| 面板 | 内容 |
|---|---|
| GPU、CPU | 更长的历史曲线。CPU 还列出前 5 个进程 |
| 内存、磁盘 | 用量条和明细。内存还列出前 5 个进程 |
| 网络 | 网速、IP、路由器、Wi-Fi 信号、速率和信道，下面是附近的 Wi-Fi 和搜索框。点一个网络展开：安全性、账号（企业级网络）和密码框，「忘记」「连接 / 断开」 |
| 蓝牙 | 蓝牙总开关和配对过的设备，连着的在前面，设备报电量的话显示电量。点一个设备展开：类型、地址、电量，「忘记」「连接 / 断开」 |
| 输入法 | 所有输入法，点一个就切过去 |
| 音量 | 当前输出设备的音量滑块（拖的时候数字跟着变），静音 |
| 电池 | 健康度、循环次数、温度 |
| 时钟 | 农历、周数 |

窗口碰不到菜单栏那一截，所以不会盖住顶栏。例外是盖满整块屏的窗口（比如 PowerPoint 放映）：这时顶栏降到它下面，窗口关掉再回来。

更想用系统菜单栏？`echo native > ~/.config/fantastic-i3/bar`，之后开机、重新加载都不显示 SketchyBar；⌥⇧↩ 照样临时打开。删掉这个文件就换回来。

<details>
<summary>实现</summary>

配置在 [`sketchybar/`](sketchybar)。网络和蓝牙面板是两个小 App 画的原生面板：`fantastic-i3-wifi` 和 `fantastic-i3-bluetooth`（由 `aero panel` 编译、启动，源码在 [`yabai/helper/panels/`](yabai/helper/panels)），因为 SketchyBar 的面板里放不了输入框；栏上的蓝牙图标也由蓝牙那个更新。GPU、CPU、内存、磁盘、网络、输入法和其它面板的内容来自 `aero-helper bar-stats`（[`yabai/helper/bar.swift`](yabai/helper/bar.swift)）；前 5 个进程只在面板开着时才算。

背景是 `aero-helper bar-backdrop`（[`yabai/helper/backdrop.swift`](yabai/helper/backdrop.swift)）。和真正的菜单栏一样，它显示壁纸顶部、重度模糊再稍微压暗。它在真正的菜单栏和状态图标之上（层级 26），把它们挡在顶栏下面；下拉菜单和控制中心照样开在它上面。它只在普通桌面上，所以跟着桌面一起滑动，不会盖住原生全屏的应用（视频、幻灯片）。它每 0.2 秒看一次有没有不走原生全屏、却盖满整块屏的窗口（比如 PowerPoint 放映）；有的话顶栏（`topmost=off`）和底板一起降到窗口下面，等它没了再回来。

详情面板也一样：面板自己的底色是透明的，底板进程在每个打开的面板后面紧贴着垫一个系统菜单材质的窗口（磨砂、圆角、一圈细亮边、系统阴影），看起来和真正的菜单栏点开的面板一样。面板里的文字用系统字体。SketchyBar 自带的 `blur_radius` 在 macOS 15 上不起作用。macOS 15 还对没有定位权限的应用隐藏 Wi-Fi 名称，所以网络项显示的是连接类型。

</details>

## 瞬间切换

没有 yabai 的脚本扩展时，切换工作区有 macOS 的滑动动画，⌥T 和 ⌥⇧⇥ 也用不了。脚本扩展要部分关闭 SIP：

1. 在恢复模式里运行 `csrutil enable --without fs --without debug --without nvram`。
2. 运行 [`yabai/setup-sa`](yabai/setup-sa)，它要求时就重启。

加载之后，缺的桌面会自动补齐。每次升级 yabai 后要再运行一次 `setup-sa`。在 macOS 15 上它还会给 yabai 的加载器打补丁，让它能注入 Dock（[yabai#2686](https://github.com/asmvik/yabai/issues/2686)）。

## 排错

- `yabai/aero status` 显示快捷键模式、脚本扩展有没有加载，以及每个桌面对应的工作区和窗口数。
- ⌥⇧ 移窗口失败会记在 `/tmp/yabai-aero-$USER/aero.log`。
- ⌃S Esc 重新加载配置。

## 文件

| 路径 | 内容 |
|---|---|
| [`install.sh`](install.sh) | 安装脚本 |
| [`yabai/yabairc`](yabai/yabairc) | yabai 配置：规则、固定工作区、信号 |
| [`yabai/aero`](yabai/aero) | 快捷键调用的工作区和窗口命令 |
| [`yabai/helper/`](yabai/helper) | aero-helper（Swift）：切换列表、剪贴板历史、截图识别、顶栏数据和背景 |
| [`yabai/helper/panels/`](yabai/helper/panels) | Wi-Fi、蓝牙面板，单独编译成一个小 App：看 Wi-Fi 名称要定位权限、读蓝牙设备要蓝牙权限，这两个权限都只能给 App |
| [`yabai/setup-sa`](yabai/setup-sa) | 脚本扩展的安装 |
| [`skhd/`](skhd) | 快捷键 |
| [`sketchybar/`](sketchybar) | 顶栏 |
| [`bin/fantastic-app-launcher`](bin/fantastic-app-launcher) | ⌥⇥、⌘⇥ 和 ⌘Space：应用启动器和窗口切换器（列表界面在 `yabai/helper/main.swift`） |
| [`bin/fantastic-clipboard`](bin/fantastic-clipboard) | ⌥⇧V 剪贴板历史（面板和记录在 `yabai/helper/clipboard.swift`） |
| [`yabai/new_window_here`](yabai/new_window_here) | ⌥D 和 ⌥⇧D |
| [`yabai/capture`](yabai/capture) | ⌥O 和 ⌥I（识别在 `yabai/helper/capture.swift`） |

安装脚本把 [`bin/`](bin) 里的每个命令链接到 `~/.local/bin`，终端里也能直接用（`fantastic-clipboard`、`fantastic-app-launcher --list`），快捷键也是从那里调的。除了上面两个，`bin/` 里还有几个独立的小工具：`center-window`（把最前面的窗口居中，AeroSpace 配置里用）、`freemps`（用 PyTorch 在 MPS 上占用指定大小的显存，默认 8 GB）、`list_brew_packages`（按占用空间列出 Homebrew 装的包）、`nvim-opener.sh`（在 kitty 里用 Neovim 打开文件）。

在 [fantastic-i3](https://github.com/mejistus/fantastic-i3) 里运行时，安装脚本还会把它的 tmux 配置（`../tmux`，Linux 和 macOS 共用）链接到 `~/.config/tmux`。

这里的其它文件夹（`kitty/`、`aerospace/`）是独立的配置，安装脚本不碰它们。Neovim 配置用 [NextVim](https://github.com/mejistus/NextVim)。
