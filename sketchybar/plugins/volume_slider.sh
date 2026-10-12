#!/bin/bash
# 音量弹出面板里的滑块：点 / 拖到哪里，音量就设成多少（SketchyBar 给出 $PERCENTAGE）。
# 下面"音量"那一行的数字也马上改：等 bar-stats 每 2 秒一次的刷新，拖的时候数字不跟着动
if [ "$SENDER" = mouse.clicked ] && [ -n "$PERCENTAGE" ]; then
    percent=${PERCENTAGE%.*}
    sketchybar --set "$NAME" slider.percentage="$percent" --set volume.level label="${percent}%"
    osascript -e "set volume output volume $percent"
fi
