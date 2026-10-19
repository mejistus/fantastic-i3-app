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

windows=$(yabai -m query --windows 2>/dev/null) || exit 0
visible=" $(yabai -m query --spaces 2>/dev/null | jq -r '.[] | select(."is-visible") | .index' | paste -sd' ' -) "
hidden=$(jq -r '.[] | select(."has-ax-reference" | not) | .id' <<<"$windows" |
    xargs "$HOME/.cache/fantastic-i3/aero-helper" ordered-out 2>/dev/null | paste -sd, -)
hide_empty=$(sed -n 's/^[[:space:]]*hidden_unactivated[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' \
    "$HOME/.config/fantastic-i3/config" 2>/dev/null | tail -1 | tr '[:upper:]' '[:lower:]')
case $hide_empty in true | yes | on | 1) hide_empty=1 ;; *) hide_empty=0 ;; esac
icons=()
while IFS=$'\t' read -r space app; do
    [ -n "$space" ] && [ "$space" -le 17 ] || continue
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
sketchybar "${args[@]}" --trigger title_change
