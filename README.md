# fantastic-i3-macOS

[中文](README.zh-CN.md) · Part of [fantastic-i3](https://github.com/mejistus/fantastic-i3), my i3 setup for Linux

An i3-style tiling setup for macOS. [yabai](https://github.com/asmvik/yabai) tiles windows, [skhd](https://github.com/asmvik/skhd) handles the keys and [SketchyBar](https://github.com/FelixKratz/SketchyBar) replaces the menu bar. There are 17 workspaces, 1 … 10 and Z X C B N M T, one per macOS desktop.

[Install](#install) · [Keys](#keys) · [Fixed workspaces](#fixed-workspaces) · [Top bar](#top-bar) · [Instant switching](#instant-switching) · [Troubleshooting](#troubleshooting) · [Files](#files)

## Install

Apple Silicon only. One line:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mejistus/fantastic-i3-macOS/main/install.sh)"
```

From a clone, run `bash install.sh` in it instead. The script is safe to rerun. It:

1. Installs Homebrew if it's missing. It asks for your login password and also installs the Xcode command-line tools.
2. When run with curl, clones the repo to `~/.local/share/fantastic-i3-macOS`, out of sight. An existing clone can be anywhere, such as the `macos` submodule of fantastic-i3.
3. Checks yabai, skhd, SketchyBar, jq and the fonts, and installs the missing ones.
4. Links the repo's `yabai`, `skhd` and `sketchybar` folders as `~/.config/yabai`, `~/.config/skhd` and `~/.config/sketchybar`; existing ones are backed up as `.bak-<date>`. Configs and scripts find each other through `~/.config`, so nothing else is linked anywhere.
5. Turns off "Automatically rearrange Spaces based on most recent use".
6. Builds aero-helper (window switcher, bar stats) and starts the services. The macOS menu bar is set to always show, and SketchyBar is drawn over it.

Then it lists what's left to do by hand:

- Give yabai and skhd Accessibility access (System Settings → Privacy & Security → Accessibility), then rerun the script.
- Add desktops in Mission Control until there are 17.

Last, it prints a key cheat sheet. Take a screenshot of it; `install.sh --keys` prints it again.

The first time the Wi-Fi and Bluetooth panels start, macOS asks whether "fantastic-i3-wifi" may use your location and whether "fantastic-i3-bluetooth" may use Bluetooth. Allow both: macOS only shows Wi-Fi names to apps with location access, and the Bluetooth panel needs Bluetooth access to list your devices.

## Keys

### Workspaces

| Key | Action |
|---|---|
| <kbd>⌥1</kbd> … <kbd>⌥9</kbd> <kbd>⌥0</kbd> | Go to workspace 1 … 10 |
| <kbd>⌥Z</kbd> <kbd>⌥X</kbd> <kbd>⌥C</kbd> <kbd>⌥B</kbd> <kbd>⌥N</kbd> <kbd>⌥M</kbd> <kbd>⌥T</kbd> | Go to workspace Z X C B N M T (desktops 11 … 17). ⌥T needs the [scripting addition](#instant-switching): macOS has shortcuts for desktops 1 … 16 only |
| <kbd>⌥</kbd> + <kbd>Caps Lock</kbd> | Workspace 10 too. Works with Caps Lock left as is or remapped to 🌐/fn |
| <kbd>⌥⇧</kbd> + the keys above | Move the window to that workspace and follow it |
| <kbd>⌃H</kbd> / <kbd>⌃L</kbd> | Previous / next workspace: 1 … 10, plus the letter workspaces that have windows |
| <kbd>⌥⇧⇥</kbd> | Move the workspace to the next monitor (needs the scripting addition) |

### Windows

| Key | Action |
|---|---|
| <kbd>⌥H</kbd> <kbd>⌥J</kbd> <kbd>⌥K</kbd> <kbd>⌥L</kbd> | Focus left, down, up, right |
| <kbd>⌥⇧H</kbd> <kbd>⌥⇧J</kbd> <kbd>⌥⇧K</kbd> <kbd>⌥⇧L</kbd> | Swap with the window on that side |
| <kbd>⌥</kbd> / <kbd>⌥⇧</kbd> + arrows | The same with arrow keys. These replace the system's move / select by word |
| <kbd>⌥F</kbd> | Fullscreen / restore |
| <kbd>⌥⇧F</kbd> | Tile ↔ float |
| <kbd>⌥-</kbd> / <kbd>⌥=</kbd> | Shrink / grow |
| <kbd>⌥R</kbd> | Resize mode: H J K L or arrows change width and height; Esc leaves |

### Switching and opening

| Key | Action |
|---|---|
| <kbd>⌥⇥</kbd> | Tap: previous app. Hold ⌥: the app list |
| <kbd>⌘⇥</kbd> | Window list, replacing the macOS app switcher. The previous window is selected, so ⌘⇥ then Return goes back to it |
| <kbd>⌘Space</kbd> | The app list straight away, instead of Spotlight. Press again to close |
| <kbd>⌥D</kbd> | Bring a Finder window to this workspace, or open one |
| <kbd>⌥⇧D</kbd> | Open a new Finder window on Documents here |
| <kbd>⌥G</kbd> | Default browser on workspace 1: focus its window there, or open one |
| <kbd>⌥⇧V</kbd> | Clipboard history: text, images and files you copied (up to 300 entries, 40 images), newest first, with a preview on the right. Type to search (pinyin too), Return pastes into the app you were in, ⌘Return only copies, ⌘⌫ deletes an entry. Items password managers mark as concealed aren't kept. Stored in `~/.config/fantastic-i3/clipboard/`, readable only by you |
| <kbd>⌥O</kbd> | Select a screen region and copy the text in it, row by row (macOS's own text recognition, offline). Chinese and English, simplified and traditional, also mixed with Japanese or Korean: the Chinese, Japanese and Korean models each read the image and the results are merged |
| <kbd>⌥I</kbd> | Select a formula and copy its LaTeX source (a SiliconFlow vision model, the same model, prompt and cleanup as the latex-ocr-queen Raycast extension). Needs your SiliconFlow API key, see below |

For ⌥I, put your SiliconFlow API key in `SILICONFLOW_API_TOKEN` (or `SILICONFLOW_API_KEY`). Commands started by skhd don't go through your shell, so `capture` takes the line that exports it from `~/.zshrc` and has zsh evaluate just that line. A keychain item also works: `security add-generic-password -U -a "$USER" -s fantastic-i3-siliconflow -w`. If Raycast also binds ⌥O / ⌥I, remove those hotkeys there.

In both lists, type to search. Keys go straight into the search box, past your input method, which stays as it was. Chinese names match by pinyin, in full or by initials (天氣: `tianqi` or `tq`). ↑ ↓ or the list's own key (⌥⇥ / ⌘⇥, add ⇧ to go up) select, Return or a click switches, Esc closes, ⌘+ / ⌘- change the font size.

- **Window list**: every window, by workspace. Running apps without windows come last; picking one works like clicking it in the Dock.
- **App list**: every app in Launchpad, one row each. Apps with windows come first, most recent first; picking one goes to its last-used window. Then running apps without windows, then the rest by name; picking one that isn't running opens it.

### Service mode: <kbd>⌃S</kbd>, then

| Key | Action |
|---|---|
| <kbd>M</kbd> | Remember the app's layout, tiled or floating, for its new windows. Tiled applies to standard windows only, so dialogs still float. Saved in `~/.config/fantastic-i3/layouts` |
| <kbd>W</kbd> | Remember the app's workspace: new windows open there and take you along. Overrides the [fixed workspaces](#fixed-workspaces). Saved in `~/.config/fantastic-i3/workspaces` |
| <kbd>F</kbd> | Tile or float every window on the workspace |
| <kbd>J</kbd> / <kbd>H</kbd> / <kbd>V</kbd> | Toggle the split direction / open the next window to the right / below |
| <kbd>R</kbd> | Resize mode |
| <kbd>Esc</kbd> | Reload the config, without restarting yabai or moving windows |

To forget a remembered app, delete its line in the file and press ⌃S Esc.

### Other

| Key | Action |
|---|---|
| <kbd>⌥⇧↩</kbd> | Hide the top bar for now to show the macOS menu bar underneath, with the app menus; press again to bring it back. Logging in or reloading SketchyBar goes back to [your choice](#top-bar) |

## Fixed workspaces

New windows of most apps open on the current workspace. A few go to a fixed one:

| App | Workspace |
|---|---|
| Microsoft Edge | 1, tiled |
| iTerm2, kitty, Terminal | 5 |
| WeChat | 10 |
| Any app you pin with ⌃S W | Where you pinned it |

- Activating one of these apps with no window (launching it from the Dock, say) switches to its workspace first, so the new window doesn't flash on the current one. Their later windows take you along.
- Picking one in the ⌥⇥, ⌘⇥ or ⌘Space list switches to its workspace before opening it.
- Activating any app from the Dock, a notification or a link takes you to its most recent window when it has none on the current workspace. One Dock click is enough, even though macOS's "switch to a Space with open windows for the application" is off.

The built-in list is in [`yabai/yabairc`](yabai/yabairc).

## Top bar

A SketchyBar bar styled like the i3 polybar (One Dark, Maple Mono NF). It is as tall as the menu bar (24 pt) and frosted like it, and it is drawn over the real menu bar, which always shows. While the bar is on, yabai's `menubar_opacity` makes the real one invisible and click-through, status icons included, so it never peeks through. The menu bar keeps its strip, so windows and desktop icons are laid out below it whether the bar is on or off. For the app menus (File, Edit, …), press ⌥⇧↩ to hide the bar.

**Left**

- An  menu that is a real macOS menu: About This Mac, System Settings, App Store, Sleep, Restart, Shut Down, Lock Screen, Log Out. Restart, shut down and log out ask first.
- Workspaces 1 … 10 and Z … T with the icons of their apps. Click one to switch. An empty letter workspace shows only while you're on it.
- The skhd mode (RESIZE / SERVICE), then the focused app and window title.

**Right**

- A theme toggle: colour or black-and-white icons. Warnings stay yellow / red and the panels stay in colour.
- GPU (Apple Silicon) and CPU, each a graph and a percentage, then memory and disk (used, counted like Finder).
- Bluetooth (grey when off), network speed (upload above download, in small type), input method (中 / EN), volume (scroll to change), battery (green above 80 %, yellow from 30 %, red below), and the date and time in the system locale (10月7日 週三 13:55).

Click an item on the right for a detail panel; click again or move away to close it. The ↗ in a panel's title opens the matching app or settings page.

| Panel | Shows |
|---|---|
| GPU, CPU | A larger history graph. CPU also lists the top 5 processes |
| Memory, disk | A usage bar and breakdown. Memory also lists the top 5 processes |
| Network | Speeds, IP, router, Wi-Fi signal, rate and channel, then nearby Wi-Fi with a search box. Click a network to expand it: security, account (enterprise networks) and password fields, Forget and Connect / Disconnect |
| Bluetooth | An on / off switch and your paired devices, connected ones first with their battery when the device reports it. Click a device to expand it: type, address, battery, Forget and Connect / Disconnect |
| Input method | Your input sources; click one to switch to it |
| Volume | A slider for the current output device (the number follows as you drag), and mute |
| Battery | Health, cycles, temperature |
| Clock | Lunar date, week number |

Windows can't reach the menu bar's strip, so they never cover the bar. A window covering a whole screen, such as a PowerPoint slideshow, is the exception: the bar drops below it until it closes.

Prefer the macOS menu bar? `echo native > ~/.config/fantastic-i3/bar` keeps SketchyBar off at login and on every reload; ⌥⇧↩ still shows it for now. Delete the file to go back.

<details>
<summary>How it's built</summary>

Config is in [`sketchybar/`](sketchybar). The network and Bluetooth panels are native panels from two small apps, `fantastic-i3-wifi` and `fantastic-i3-bluetooth` (built and started by `aero panel`, sources in [`yabai/helper/panels/`](yabai/helper/panels)), because SketchyBar panels can't hold text fields; the Bluetooth one also keeps the Bluetooth icon up to date. GPU, CPU, memory, disk, network, input method and the other panels' contents come from `aero-helper bar-stats` ([`yabai/helper/bar.swift`](yabai/helper/bar.swift)); the top-5 process lists are computed only while a panel is open.

The background is `aero-helper bar-backdrop` ([`yabai/helper/backdrop.swift`](yabai/helper/backdrop.swift)). Like the real menu bar, it shows the top of the wallpaper heavily blurred and slightly darkened. It sits just above the real menu bar and its status icons (level 26), hiding them under the bar; dropdown menus and Control Center still open above it. It sits on the regular desktops only, so it slides in and out with them and never covers a native-fullscreen app (videos, slides). Every 0.2 s it checks whether a window covers a whole screen without native fullscreen, such as a PowerPoint slideshow; if so, the bar (`topmost=off`) and the backdrop drop below windows until it's gone.

The detail panels get the same treatment: their own fill is transparent, and the backdrop process puts a window with the system menu material right behind each open panel (frosted, rounded, with a hairline border and the system shadow), so they look like the panels the real menu bar opens. Panel text uses the system font. SketchyBar's own `blur_radius` has no effect on macOS 15. macOS 15 also hides the Wi-Fi name from apps without Location access, so the network item shows the connection type instead.

</details>

## Instant switching

Without yabai's scripting addition, workspaces switch with macOS's slide animation, and ⌥T and ⌥⇧⇥ don't work. The scripting addition needs SIP partly disabled:

1. In Recovery, run `csrutil enable --without fs --without debug --without nvram`.
2. Run [`yabai/setup-sa`](yabai/setup-sa), and reboot if it asks.

Once it's loaded, missing desktops are created automatically. Run `setup-sa` again after every yabai upgrade. On macOS 15 it also patches yabai's loader so it can inject into the Dock ([yabai#2686](https://github.com/asmvik/yabai/issues/2686)).

## Troubleshooting

- `yabai/aero status` shows the key mode, whether the scripting addition is loaded, and every desktop with its workspace and window count.
- Failed ⌥⇧ moves are logged to `/tmp/yabai-aero-$USER/aero.log`.
- ⌃S Esc reloads the config.

## Files

| Path | What |
|---|---|
| [`install.sh`](install.sh) | The installer |
| [`yabai/yabairc`](yabai/yabairc) | yabai config: rules, fixed workspaces, signals |
| [`yabai/aero`](yabai/aero) | Workspace and window commands the keys call |
| [`yabai/helper/`](yabai/helper) | aero-helper (Swift): the switcher lists, clipboard history, screenshot recognition, bar stats and backdrop |
| [`yabai/helper/panels/`](yabai/helper/panels) | The Wi-Fi and Bluetooth panels, built as their own small app because location access (needed for Wi-Fi names) and Bluetooth access are only granted to apps |
| [`yabai/setup-sa`](yabai/setup-sa) | Scripting addition setup |
| [`skhd/`](skhd) | Keys |
| [`sketchybar/`](sketchybar) | Top bar |
| [`yabai/window_switcher`](yabai/window_switcher) | ⌥⇥, ⌘⇥ and ⌘Space |
| [`yabai/new_window_here`](yabai/new_window_here) | ⌥D and ⌥⇧D |
| [`yabai/capture`](yabai/capture) | ⌥O and ⌥I (recognition in `yabai/helper/capture.swift`) |

The other folders here (`kitty/`, `nvim/`, `aerospace/`) are standalone configs; the installer doesn't touch them.
