#!/bin/bash
# 配色和文字字体。彩色主题是 One Dark，底色和前景色与 polybar（../../polybar/color.ini）一致。格式 0xAARRGGBB。
# 主题：color（彩色）/ mono（黑白，像原生菜单栏：栏上的图标、文字、曲线都是白色，文字用系统字体，
#       只有表示警告的 WARN / ALERT 保留黄、红）。弹出面板两种主题都是彩色的。
# 栏右边一组最左边的开关（plugins/theme.sh）切换，记在 defaults 的 fantastic-i3.sketchybar theme 里（aero-helper 也读它）
# 浅色 / 深色（LOOK）：和原生菜单栏一样跟着壁纸走。壁纸顶上那一条亮的时候系统菜单栏是浅底黑字，暗的时候是深底白字；
# aero-helper bar-backdrop 从系统读出主屏选了哪种，记在 defaults 的 fantastic-i3.sketchybar look 里，变了就重新加载。
# 浅色时只换栏上的颜色，弹出面板跟着系统的深色外观，不变（原生的也是这样），所以面板用 POPUP_FG、PANEL_*
export THEME=$(defaults read fantastic-i3.sketchybar theme 2>/dev/null || echo color)
export LOOK=$(defaults read fantastic-i3.sketchybar look 2>/dev/null || echo dark)
export BAR_COLOR=0x00282c34   # 栏底色全透明：底色完全交给 aero-helper bar-backdrop 的底板（和原生菜单栏一样是模糊的壁纸）。
                              # 想更不透就加大前两位（00 → 40 → 80），叠一层 #282c34 的深色
export DARK=0xff282c34        # 彩色底上的深色字（skhd 模式标签）
export ITEM_BG=0x24ffffff     # 弹出面板的分隔线、进度条和滑块底（半透明白，和原生菜单的分隔线一样）
export SPACE_BG=0x33ffffff    # 当前工作区的底色（半透明白，和原生菜单栏点开菜单时的高亮一样）
export FG=0xffeaeaea          # 主要文字
export FG_ALT=0xff9c9c9c      # 次要文字（窗口标题）
export FG_DIM=0x66ffffff      # 弹出面板里的小标题、提示行（半透明白：在系统材质上和原生的三级文字一样）
export POPUP_FG2=0x99ffffff   # 弹出面板里左边的名称、右边次要的数字（原生的二级文字）
export FG_FAINT=0x73ffffff    # 空工作区的数字（半透明白，玻璃底上也看得见）
# 调色板：弹出面板一直用它；栏上用下面的 BAR_*（彩色主题就是调色板，黑白主题换成白）
export BLUE=0xff61afef
export GREEN=0xff98c379
export YELLOW=0xffe5c07b
export RED=0xffe06c75
export PURPLE=0xffc678dd
export CYAN=0xff56b6c2
export ORANGE=0xffd19a66
export BLUE_FILL=0x4461afef   # 弹出面板里曲线下面的填充
export BAR_BLUE=$BLUE BAR_GREEN=$GREEN BAR_YELLOW=$YELLOW BAR_PURPLE=$PURPLE BAR_CYAN=$CYAN BAR_ORANGE=$ORANGE
export BAR_BLUE_FILL=0x4461afef BAR_PURPLE_FILL=0x44c678dd   # 栏上 CPU、GPU 曲线下面的填充
export GREEN_DIM=0xb398c379   # 网速的 ↓（淡一些，数字还是白的）
export RED_DIM=0xb3e06c75     # 网速的 ↑
export WARN=0xffe5c07b        # 警告（黄）、严重（红）：电量低之类，两种主题都用
export ALERT=0xffe06c75

# 弹出面板的文字用系统字体（和原生菜单栏里点开的面板一样，中文自动用苹方），两种主题都是
export POPUP_FONT=.AppleSystemUIFont
# 文字字体和四档字重（图标一直用 sketchybarrc 里的 Maple Mono NF 的字形），APP_NAME 是当前应用名的字重。
# PERCENT_GLYPH / RATE_GLYPH：这个字体下最宽的百分比（"40%"）、网速（最多 4 个字符，"400M"）有多宽，sketchybarrc 用来定固定宽度
export TEXT_FONT="Maple Mono NF" BOLD=Bold SEMIBOLD=SemiBold MEDIUM=Medium REGULAR=Regular APP_NAME=SemiBold
export PERCENT_GLYPH=23 RATE_GLYPH=28

if [ "$THEME" = mono ]; then
    # 黑白：文字纯白，栏上的强调色都换成白，箭头、曲线填充用半透明白（弹出面板不变）
    export FG=0xffffffff FG_ALT=0xb3ffffff
    export BAR_BLUE=$FG BAR_GREEN=$FG BAR_YELLOW=$FG BAR_PURPLE=$FG BAR_CYAN=$FG BAR_ORANGE=$FG
    export GREEN_DIM=0x99ffffff RED_DIM=0x99ffffff BAR_BLUE_FILL=0x33ffffff BAR_PURPLE_FILL=0x33ffffff
    # 系统字体（和原生菜单栏一样，中文自动用苹方），字重比 Maple Mono 降一档；数字由 sketchybarrc 设成等宽（tnum）
    export TEXT_FONT=.AppleSystemUIFont BOLD=Semibold SEMIBOLD=Medium MEDIUM=Regular REGULAR=Regular APP_NAME=Bold
    export PERCENT_GLYPH=28 RATE_GLYPH=32
fi

# 面板（总是深色）用的：上面定好的深色那一套
export POPUP_FG=$FG PANEL_BLUE=$BAR_BLUE PANEL_GREEN=$BAR_GREEN PANEL_YELLOW=$BAR_YELLOW PANEL_PURPLE=$BAR_PURPLE PANEL_ORANGE=$BAR_ORANGE
export MODE_FG=$DARK   # skhd 模式标签（彩色底）上的字

if [ "$LOOK" = light ]; then
    # 浅色栏：原生的字是黑色、不透明度 86%（截图量的：白底上 37，193 的底上 28）。
    # 彩色主题换成 One Light 的配色（One Dark 的浅色版），黑白主题都换成黑
    export SPACE_BG=0x1f000000 FG_FAINT=0x66000000 GREEN_DIM=0xb350a14f RED_DIM=0xb3e45649
    export WARN=0xffc18401 ALERT=0xffe45649 MODE_FG=0xffffffff
    if [ "$THEME" = mono ]; then
        export FG=0xdb000000 FG_ALT=0x8c000000
        export BAR_BLUE=$FG BAR_GREEN=$FG BAR_YELLOW=$FG BAR_PURPLE=$FG BAR_CYAN=$FG BAR_ORANGE=$FG
        export GREEN_DIM=0x8c000000 RED_DIM=0x8c000000 BAR_BLUE_FILL=0x29000000 BAR_PURPLE_FILL=0x29000000
    else
        export FG=0xff383a42 FG_ALT=0xff696c77
        export BAR_BLUE=0xff4078f2 BAR_GREEN=0xff50a14f BAR_YELLOW=0xffc18401 BAR_PURPLE=0xffa626a4 BAR_CYAN=0xff0184bc BAR_ORANGE=0xff986801
        export BAR_BLUE_FILL=0x444078f2 BAR_PURPLE_FILL=0x44a626a4
    fi
fi
