# EchoTerm · 像素入场

46 秒宣传片 v7，1920 × 1080，60 fps，H.264 + AAC。

成片：`output/EchoTerm-Promo-v7-46s.mp4`。

本版在 v6 的 41 秒内容前增加 5 秒入场。以浅色留白和蓝色像素开始，先形成终端提示符，再让像素沿同一个玻璃窗口流向输入光标。镜头靠近、窗口就位后，功能标题渐显，接着输入第一条命令。后续镜头、停留节奏与功能叙事沿用 v6。

| 时间 | 入场画面 |
| --- | --- |
| 0–约 1 秒 | 蓝色像素沿弧线进入，聚成 `> _` 提示符 |
| 约 1–2.35 秒 | 提示符与 EchoTerm 名称停留 |
| 2.35–3.9 秒 | 像素展开、沿玻璃边缘流动；终端从远景靠近，背景窗口带有轻微视差 |
| 3.9–约 5 秒 | 像素流入输入光标，窗口到达功能镜头位置；标题开始渐显 |
| 5 秒以后 | 自然开始输入命令，接入 v6 原有内容 |

## 连贯性

入场和功能镜头使用同一终端画面、相同玻璃背景与透视计算。5 秒连接点的原始 RGB 画面最大通道差为 0，窗口位置和相机缓动衔接一致。未使用硬切、插入静帧或整体变速。32 个蓝色像素组成提示符，展开时分流为 96 个像素，最终汇入实际输入光标的位置。

主内容的时间安排整体后移 5 秒，v6 已确认的完成态停留时长保持不变。SRT 同步平移。开场音乐增加了柔和和声、两次轻音和稀疏颗粒声，在 5 秒附近持续衔接原有配乐。

## 素材

沿用现有 EchoTerm 录制素材、原生 Swift 像素角色、字体渲染器和原创配乐生成器。界面、玻璃、三维会话、跨 Block 说明和流动像素使用已有宣传片的合成方式；AI 演示为本地脚本化 Provider。新开场属于程序化镜头动画。

本次仅修改 `promo/v7`，没有修改或重启应用。v6 原片保留。

## 文件

- `source/render-film.py`：新增入场镜头与原有画面渲染。
- `source/timing.py`：5 秒开场偏移与 v6 的停留时间映射。
- `source/make-soundtrack.py`：开场音效、和声和同步后移的原配乐。
- `source/opening-check.json`：301 帧轨迹检查与连接点画面一致性。
- `source/verify-film.py`：完整解码、帧数与编码后关键帧验证。
- `source/media-check.json`：最终媒体检查记录。
- `previews/opening-contact.jpg`：入场设计预览。
- `previews/encoded-contact.jpg`：最终编码后的关键帧。

使用本机 Python `python3 (activated virtual environment)`，NumPy、OpenCV、Pillow、FFmpeg 以及 AppKit 字体渲染工具。先运行 `make-soundtrack.py` 并通过 FFmpeg loudnorm 生成 `soundtrack.wav`，再运行 `render-film.py --render` 和 `verify-film.py`。

## 成片验证

最终文件 46.000 秒、1920 × 1080、60 fps、2760 帧；H.264 / AAC 48 kHz 双声道。完整解码通过，已检查编码后的入场与衔接关键帧。配乐实测约 -17.41 LUFS、真峰值 -4.57 dBFS。
