# 固定源与派生关系

源提交：https://github.com/xiaoland/shenglin/tree/71baa5f5aa54a486484e4a302d181430afc48033

- Design/AppIcon.svg：Mac 青色圆角底板、白色三节点外形与五道镂空声波；原尺寸周边透明。
- Design/AppIcon-iPad.svg：相同几何，青色满版、无预裁圆角。
- Design/Mark-Monochrome.svg 与 Design/Mark-White.svg：原有透明独立标记（mask 实现）。本包转为 evenodd 复合路径，保持真实可编辑镂空。
- Design/MenuBarIcon.svg：原有不含声波的单色小标记，为 micro 简化提供依据。
- scripts/build-macos-icon.sh：原有小尺寸底板扩大方案（87.5% 对常规 80.46875%）。
- README.md：确认 Design 目录为图标、透明标记及菜单栏单色标记来源。

regular 独立标记品牌青色是既有品牌色的应用；上游独立文件本身提供黑/白。compact 三孔和标记光学放大为此次制作的明确派生。所有原文件逐字保存于 source，可与固定提交对照。
