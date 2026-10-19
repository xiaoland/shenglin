# 声邻 Logo 素材

各平台现用图标原稿保留在本目录，应用继续使用各平台已提交的资源。[2026-10-19 Logo Pack](LogoPacks/2026-10-19/README.md) 是一般用途独立标记及多配色、多尺寸导出的默认入口，也是基于现有身份制作的完整快照；本次收录没有更换应用图标。

## 选用素材

品牌青色为 `#065E6E`，黑色为 `#000000`，白色为 `#FFFFFF`。独立标记适合正文、网页和配图；带青色底板的应用图标用于展示 App 身份。`transparent` 对独立标记表示背景透明，对应用图标仅表示底板外围透明。

以下路径均位于 [Logo Pack 快照](LogoPacks/2026-10-19/) 内：

| 用途 | 素材 |
| --- | --- |
| 浅底上的青色独立标记 | `svg/mark/mark-brand-on-transparent-regular.svg` 或 `png/mark/mark-brand-on-transparent-{尺寸}.png` |
| 深底上的白色独立标记 | `svg/mark/mark-white-on-transparent-regular.svg` 或 `png/mark/mark-white-on-transparent-{尺寸}.png` |
| 浅底上的黑色独立标记 | `svg/mark/mark-black-on-transparent-regular.svg` 或 `png/mark/mark-black-on-transparent-{尺寸}.png` |
| 带底板的应用图标 | `svg/app-icon/`、`png/app-icon/`；`brand` 表示青色底板和白色图形 |
| 保留现行平台几何的导出 | `platform-originals/`；Mac 带透明留白，iPad 满版且不预裁圆角，菜单栏为无声波轮廓 |
| 配色与尺寸对照 | [contact-sheet.png](LogoPacks/2026-10-19/contact-sheet.png) |

原 `Mark-Monochrome.svg`、`Mark-White.svg` 独立标记已从 Design 根目录移除，其 SVG 原稿保存在快照的 `source/Design__Mark-Monochrome.svg` 和 `source/Design__Mark-White.svg`；旧 PNG 可从 Git 历史恢复。新用途请从快照的 `svg/mark/` 或 `png/mark/` 选择，不要把冻结的 `source/` 当作日常编辑入口。

PNG 提供 16、24、32、48、64、128、256、512、1024 像素。包内按导出像素分档，SVG 文件名显式标注光学档位；需要特定档位的倍图时，从该档 SVG 导出，勿放大小尺寸 PNG。

| 光学档位 | 包内 PNG 尺寸 | 独立标记 | 应用图标 |
| --- | --- | --- | --- |
| `micro` | 16、24 px | 沿用菜单栏无声波轮廓，整体放大 14% | 去除声波，底板宽度占画板 87.5% |
| `compact` | 32、48 px | 五道声波改为三道，整体放大 6% | 三道声波，底板占 87.5% |
| `regular` | 64 px 及以上 | 保留现有五道声波与画板比例 | 五道声波，底板占 80.46875% |

`micro`、`compact` 是本包的光学派生，尚未接入各端应用。Mac 现有脚本仅在 16/32 像素减小外围留白，仍保留五道声波，与这两档不是同一方案。原彩在黑底上对比较弱，细小标记优先选白色。包内没有输出白底白标、黑底黑标等不可见组合。

## 原稿与应用资源

本目录顶层 `AppIcon.svg`、`AppIcon-iPad.svg` 和 `MenuBarIcon.svg` 是仍在使用的平台原稿入口。应用构建直接消费下表中的平台资源，修改原稿不会自动同步全部平台。

| 用途 | 原稿或现有依据 | 应用资源与更新方式 |
| --- | --- | --- |
| Mac 应用图标 | [AppIcon.svg](AppIcon.svg) | [AppIcon.png](../MacGUI/AppIcon.png)、[AppIcon.icns](../MacGUI/AppIcon.icns)；运行 [`scripts/build-macos-icon.sh`](../scripts/build-macos-icon.sh) 生成，需 librsvg 和 macOS `iconutil`。保留 Mac 外围透明留白。 |
| Mac 菜单栏 | [MenuBarIcon.svg](MenuBarIcon.svg) | [MenuBarIcon.pdf](../MacGUI/MenuBarIcon.pdf)；作为 template 图像加载，当前无专用再生脚本。 |
| iPad 应用图标 | [AppIcon-iPad.svg](AppIcon-iPad.svg) | [AppIcon.png](../iPad/Assets.xcassets/AppIcon.appiconset/AppIcon.png)；1024 像素 RGB 满版图，由 asset catalog 引用，当前无专用再生脚本。 |
| Android 启动图标 | `AppIcon-iPad.svg` 的路径与配色 | [ic_shenglin.xml](../Android/app/src/main/res/drawable/ic_shenglin.xml)、[ic_shenglin_foreground.xml](../Android/app/src/main/res/drawable/ic_shenglin_foreground.xml)、[colors.xml](../Android/app/src/main/res/values/colors.xml)；保留 adaptive icon 的前景、背景层与安全区缩放，当前无专用再生脚本。 |
| 浏览器扩展 | 现有四档 PNG，仓库未记录其完整导出步骤 | [public/icons/](../BrowserExtension/public/icons/) 中的 `icon16.png`、`icon32.png`、`icon48.png`、`icon128.png`；由 WXT 配置和弹窗引用，当前无专用再生脚本。 |

平台图标变更须同步检查资源引用、尺寸和平台样式。包内的通用 PNG 不能直接替代 Android adaptive icon 的分层资源；Mac 带留白的图标也不能代替 iPad 满版图。

## 快照来源与验证

`LogoPacks/2026-10-19/` 原样收录用户提供的 `shenglin` 包：30 个 SVG 主版、90 个派生 PNG、12 个平台原版 PNG，以及预览、清单、脚本和固定输入。[SOURCES.md](LogoPacks/2026-10-19/SOURCES.md) 记录来源提交 `71baa5f5aa54a486484e4a302d181430afc48033` 和派生关系。导入时，`source/` 中的五份 SVG、README、LICENSE 和 Mac 图标脚本均与该提交及当前仓库逐字一致。

`source/` 仅保存这次交付的历史输入，不是第二套可编辑原稿。包内 `svg/`、`png/`、`platform-originals/` 也属于该次交付；未来原稿变化不应倒改这份快照。现行原稿与应用资源仍按上表维护。

在仓库根目录执行只读完整性检查：

```sh
(cd Design/LogoPacks/2026-10-19 && shasum -a 256 -c checksums.sha256)
```

原始校验表覆盖 149 个文件，不包含校验表自身和 `validation.json`。`manifest.json` 另记录 90 个派生 PNG 的路径、像素尺寸、光学档位、透明度范围与 SHA-256；`validation.json` 是交付方留存的检测记录。

包内 `generate.py`、`validate.py` 作为交付记录保留。需要重现导出时，在快照副本中按包内说明操作；生成依赖 Python 3、Pillow 和 Inkscape，不能替代现行平台生成链。生成器除读取固定原稿外，还单独编码声波、颜色和缩放，仅改输入路径不能保证跟随原稿变化。`validate.py` 会重写校验表及报告，并写入固定的人工视觉检查文字，不能用它证明文件未被修改或本轮完成了视觉检查。

项目代码使用 [MIT 许可证](../LICENSE)；附带代码许可证不自动授予品牌或商标使用权。
