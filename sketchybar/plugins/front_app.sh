#!/bin/bash
# 当前应用（图标 + 名字）和窗口标题。
# front_app_switched 时 $INFO 是应用名；window_focus / title_change 由 yabairc 触发（space_apps.sh 显示 / 藏起工作区后也触发）。
# 标题太长会和右边一组叠在一起（屏幕缩放调大、能放的点数少时）：截短、末尾加 …。放得下多宽：每块屏上从应用名后面
# 到右边一组最左边那项（主题开关）之间，减掉标题自己的边距和 12 的空，取最窄的那块屏（栏上的文字所有屏都一样）；
# 量宽度用 aero-helper text-fit，字体和 sketchybarrc 里 window_title 的一样
export PATH=/opt/homebrew/bin:/usr/bin:/bin
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icon_map.sh"
HELPER="$HOME/.cache/fantastic-i3/aero-helper"

# yabai 偶尔会卡住一阵（睡醒之后有查询一直不回的时候）：3 秒就放弃，照样显示前台应用和标题
qyabai() { perl -e 'alarm 3; exec @ARGV or exit 127' -- yabai "$@" 2>/dev/null; }

win=$(qyabai -m query --windows --window)
app=$(jq -r '.app // empty' <<<"$win" 2>/dev/null)
title=$(jq -r '.title // empty' <<<"$win" 2>/dev/null)
if [ "$SENDER" = front_app_switched ] && [ -n "$INFO" ] && [ "$INFO" != "$app" ]; then
    # yabai 的焦点窗口有时跟不上（比如切到没有窗口的 Finder）：以前台应用为准，不显示标题
    app=$INFO
    title=
fi
[ -n "$app" ] || app=$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | sed 's/.*="\(.*\)"/\1/')
[ "$title" = "$app" ] && title=

__icon_map "$app"
sketchybar --set front_app icon="$icon_result" label="$app"   # 先设：标题从它后面开始
if [ -n "$title" ] && [ -x "$HELPER" ]; then
    # 8 = 两项之间的 6 + 标题 label 左边的 2；右边 label 的 4 + 项的 3 + 空 12
    room=$(sketchybar --query front_app --query theme | jq -rs '
        (.[0].bounding_rects // {}) as $app | (.[1].bounding_rects // {}) as $right
        | [$app | to_entries[] | select(.value.origin[0] > -9000) | .key as $d
           | select($right[$d] != null and $right[$d].origin[0] > -9000)
           | $right[$d].origin[0] - (.value.origin[0] + .value.size[0]) - 8 - 19]
        | if length > 0 then min else empty end' 2>/dev/null)
    [ -n "$room" ] && title=$("$HELPER" text-fit "$TEXT_FONT:$REGULAR:13.0" "$room" "$title")
fi
sketchybar --set window_title label="$title" drawing="$([ -n "$title" ] && echo on || echo off)"
