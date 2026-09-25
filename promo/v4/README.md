# EchoTerm · 一个入口

30 秒产品宣传片 v4。1920 × 1080，60 fps，H.264 + AAC。

成片：`output/EchoTerm-Promo-v4-30s.mp4`

本版更新最后的外观镜头：去掉具体透明度数值，展示无数值的透明度滑杆与通透 / 柔和 / 磨砂切换，并展开雾蓝、鸢尾、琥珀三扇主题窗口。保留 v3 的统一入口开场、跨会话查找、配乐与 30 秒节奏。

| 时间 | 内容 |
| --- | --- |
| 00:00–00:08.4 | 第一屏「EchoTerm · AI Native 终端」「命令与问答，一个入口。」输入测试命令 → 执行结果 → 同一位置直接提问 → Echo 自动接收、思考、回答 → 在新 Block 接着输入命令，全程没有模式切换 |
| 00:08.4–00:11.2 | Echo 像素从回答区飞出，组成标题里的「块」字，展示 Block 结构 |
| 00:11.2–00:21.7 | S2 提问 → 查找 S1 → 读取 Block 03 → 高亮原始配置 → 回到完整的会话关系 |
| 00:21.7–00:25.8 | 透明度与毛玻璃可调；雾蓝 / 鸢尾 / 琥珀三扇主题窗口展开，相机环绕 |
| 00:25.8–00:30 | 像素构成 EchoTerm 字标；「命令与 AI，无感衔接。」 |

## 素材说明

本片是**真实界面素材与产品演示动画合成**，不是一镜到底的原始录屏。

- 基础素材来自 EchoTerm 0.10.10。录制设置为雾蓝、25% 背景不透明度、通透毛玻璃。隔离窗口素材不含桌面，因此玻璃背景后期合成。
- 开场为连续输入体验的说明动画：复用已录制的测试命令、结果与 AI 演示文案，以原生字体重新排版，保证打字、流式回答、上滚以及相机运动都是 60fps。普通命令与问答输入落在同一视觉坐标，没有选择输入模式的步骤。
- 开场末尾展示的 `curl localhost:4317/health` 仅输入，未展示执行或伪造返回结果。
- AI 演示使用本地脚本化 Provider；视频里的响应时间不代表远程模型实测性能。
- 读取 S1 / Block 03 并跳转的操作在录制中真实执行，工具审计记录位于 `../source/demo-audit.jsonl`。
- Echo 图形、表情插值、双环与眨眼来自应用的 Swift 像素实现。飞出窗口、组字、空间会话地图、镜头为宣传片动效。
- 配乐由项目内合成器生成，转场音效按新版时间点重新对齐。
- v3 原片已保留。外观窗口由既有界面素材按应用主题配色合成；滑杆与材质切换是宣传片说明动画，不是原始设置录屏。毛玻璃展示现有的三种材质，不暗示软件具有连续像素半径设置。
- 像素飞出的起点和大小随新的中心窗口同步，继续连贯组成片尾字标。
- 本版只修改宣传片文件，不改动或重启用户的 EchoTerm 应用。

## 编辑与验证

- `source/render-film.py`：连续输入动画、图层、镜头、像素路径与编码。
- `source/ExportPixels.swift`：1800 帧原生像素角色动画。
- `source/TextRender.swift`：macOS 原生中英文字体与等宽命令字体。
- `source/make-soundtrack.py`：原创配乐、像素与转场音效。
- `source/verify-film.py`：检查分辨率、帧率、帧数、时长、完整解码并提取成片关键帧。
- `source/media-check.json`：最终验证记录。

渲染依赖：macOS / Swift / AppKit，Python 3 + Pillow / NumPy / OpenCV，FFmpeg。
基础录制素材引用 `../stills` 与 `../footage`；所有路径按脚本所在目录解析。

```sh
swift promo/v4/source/ExportPixels.swift promo/v4/assets/echo-60fps.json
swiftc promo/v4/source/TextRender.swift -o promo/v4/source/text-render
python3 promo/v4/source/make-soundtrack.py
ffmpeg -y -i promo/v4/source/score.wav -af loudnorm=I=-18:TP=-1.5:LRA=8 -ar 48000 promo/v4/source/soundtrack.wav
python3 promo/v4/source/render-film.py --render
python3 promo/v4/source/verify-film.py
```

## 本版检查结果

- 成片 30.000 秒、1920 × 1080、60 fps，共 1800 帧；H.264 / AAC 立体声，完整解码通过。
- 已检查编码后的主题展示、材质切换、像素飞出和片尾关键帧。
- 开场、统一输入、跨会话定位与片尾的抽样源帧和 v3 逐像素一致；配乐文件完全一致。
- 原片保留在 `../v3/output`。
