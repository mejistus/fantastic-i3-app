#!/bin/bash
# 每个工作区上有哪些应用：名字后面跟它们的图标；空工作区的名字变暗、不显示图标。
# 字母工作区（桌面 11-17）空着又不是当前的时候整个不显示，所以切桌面（space_change）时也要刷新。
# ~/.config/fantastic-i3/config 里 hidden_unactivated=true 时数字工作区也这样（空着又不是当前的就不显示）。
# 显示 / 藏起之后左边一组变宽变窄，触发 title_change：front_app.sh 重新算窗口标题放得下多长
# 窗口来自 yabai：只算普通窗口。yabai 刚启动时，还没去过的桌面上的窗口它拿不到细节（没有 AX 引用、
# 类型为空），这些也算上；但"关了窗口但还在后台"的应用（腾讯会议、微信）留下的也是这样，
# 它们其实被收起来了，哪儿都看不到：问 aero-helper 把这些去掉（helper 还没编译时就一律算上）。
export PATH=/opt/homebrew/bin:/usr/bin:/bin
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icon_map.sh"
STATE="/tmp/yabai-aero-${USER:-$(id -un)}"

# yabai 偶尔会卡住一阵（睡醒之后会有查询一直不回的时候）：3 秒就放弃。不然脚本一直堵着，
# 之后每个事件再多一个进程，越积越多（2026-10-22 醒来后积了 5 个，栏也就不刷新了）
qyabai() { perl -e 'alarm 3; exec @ARGV or exit 127' -- yabai "$@" 2>/dev/null; }

# 同一时间只跑一个：进出原生全屏时 yabai 会连发好几个 space_windows_change / space_change，
# 每个都跑一遍的话左边的工作区一秒要重画十几次（一直闪），CPU 也飙。跑着的时候来的事件只记一笔，
# 跑完再补一遍；状态和上次一样就不碰 SketchyBar（见下面的 space-apps.state）
mkdir -p "$STATE"
if ! mkdir "$STATE/space-apps.lock" 2>/dev/null; then
    pid=$(cat "$STATE/space-apps.lock/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        touch "$STATE/space-apps.dirty"
        exit 0
    fi
    rm -rf "$STATE/space-apps.lock"   # 上次被打断留下的
    mkdir "$STATE/space-apps.lock" 2>/dev/null || { touch "$STATE/space-apps.dirty"; exit 0; }
fi
echo $$ >"$STATE/space-apps.lock/pid"
trap 'rm -rf "$STATE/space-apps.lock"' EXIT

while :; do
    rm -f "$STATE/space-apps.dirty"

    windows=$(qyabai -m query --windows) || exit 0
    spaces=$(qyabai -m query --spaces) || exit 0
    # 原生全屏的应用自己占一个桌面（is-native-fullscreen），不算工作区：它的窗口不画图标、也不参与
    # "可见 / 空工作区显示"的判断，进出全屏时才不会让左组的图标来回跳、变宽变窄（配合 aero spaces-changed）
    visible=" $(jq -r '.[] | select(."is-visible") | select(."is-native-fullscreen" | not) | .index' <<<"$spaces" | paste -sd' ' -) "
    fullscreen=" $(jq -r '.[] | select(."is-native-fullscreen") | .index' <<<"$spaces" | paste -sd' ' -) "
    # 全屏桌面开着时，"可见"要沿用进全屏前记下的那一份：这时底下的普通桌面报的是不可见，
    # 空着的工作区会一个个藏起来，左边一组跟着变宽变窄（也是闪）
    if [ -n "${fullscreen// /}" ]; then
        visible=$(cat "$STATE/space-apps-visible" 2>/dev/null) || visible=" "
    else
        printf '%s' "$visible" >"$STATE/space-apps-visible"
    fi
    hidden=$(jq -r '.[] | select(."has-ax-reference" | not) | .id' <<<"$windows" |
        xargs "$HOME/.cache/fantastic-i3/aero-helper" ordered-out 2>/dev/null | paste -sd, -)
    hide_empty=$(sed -n 's/^[[:space:]]*hidden_unactivated[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' \
        "$HOME/.config/fantastic-i3/config" 2>/dev/null | tail -1 | tr '[:upper:]' '[:lower:]')
    case $hide_empty in true | yes | on | 1) hide_empty=1 ;; *) hide_empty=0 ;; esac
    icons=()
    while IFS=$'\t' read -r space app; do
        [ -n "$space" ] && [ "$space" -le 17 ] || continue
        [[ $fullscreen == *" $space "* ]] && continue
        __icon_map "$app"
        # 拿不到细节的窗口，yabai 报的是进程名（如 zotero），图标表里是 Zotero：首字母大写再查一次
        [ "$icon_result" = ":default:" ] && __icon_map "$(tr '[:lower:]' '[:upper:]' <<<"${app:0:1}")${app:1}"
        icons[space]+=" $icon_result"
    done < <(jq -r --argjson hidden "[$hidden]" '.[] | select(.id | IN($hidden[]) | not)
        | select(.subrole == "AXStandardWindow" or (."has-ax-reference" | not)) | "\(.space)\t\(.app)"' <<<"$windows" | sort -u)

    args=()
    for i in $(seq 17); do
        if [ -n "${icons[i]}" ]; then
            args+=(--set "space.$i" label="${icons[i]# }" label.drawing=on icon.color="$FG")
        else
            args+=(--set "space.$i" label.drawing=off icon.color="$FG_FAINT")
        fi
        if [ "$i" -gt 10 ] || [ "$hide_empty" = 1 ]; then
            if [ -n "${icons[i]}" ] || [[ $visible == *" $i "* ]]; then
                args+=(--set "space.$i" drawing=on)
            else
                args+=(--set "space.$i" drawing=off)
            fi
        fi
    done
    # 和上次画的一样就不碰 SketchyBar：全屏动画里事件是一串一串来的，多数时候结果没变
    state=$(printf '%s\n' "${args[@]}")
    if [ "$state" != "$(cat "$STATE/space-apps.state" 2>/dev/null)" ]; then
        printf '%s' "$state" >"$STATE/space-apps.state"
        sketchybar "${args[@]}" --trigger title_change
    fi

    [ -e "$STATE/space-apps.dirty" ] || break
done
