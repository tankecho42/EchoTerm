# EchoTerm 宣传片工程

最新中英文版本均为 **46 秒 · 1920 × 1080 · 60 fps**，H.264 / AAC。

| 版本 | 成片 | 工程 |
| --- | --- | --- |
| 英文 | [English film](v10-en/output/EchoTerm-Promo-English-v10-46s.mp4) | [v10-en](v10-en/README.md) |
| 中文 | [中文宣传片](v8/output/EchoTerm-Promo-v8-46s.mp4) | [v8](v8/README.md) |

影片从命令与问答的统一入口开始，展示 Block、跨 Session 查找与跳转、像素 Echo，以及主题与毛玻璃效果。浅色场景、空间运镜和流动像素贯穿各幕。

## 仓库内容

- `stills/`、`footage/`：独立演示环境的界面与背景素材。
- `source/`：最初版本的分镜、脚本化 AI Provider、布景与渲染源码。
- `v2/` 至 `v10-en/`：历次设计的源码、字幕和验证记录。
- 最新中英文成片与海报直接随仓库保存，无需 Git LFS。

旧版成片、预览帧、文字缓存、编译后的 Swift 工具、像素采样 JSON、配乐 WAV 和本机调试日志由 `.gitignore` 排除。它们仍保留在原制作工作区；重建所需的源文件与录制素材已纳入仓库。各版本 README 中提到的预览图与旧版视频需重新渲染，历史验证记录描述的是原制作时的检查结果。

## 重建最新版本

需要 macOS、Swift Command Line Tools、FFmpeg（含 `ffprobe`）和 Python 3。Python 依赖见 [requirements.txt](requirements.txt)。字体使用 macOS 原生 SF 与苹方。以下命令在仓库根目录执行：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r promo/requirements.txt

# 中文版本改为 promo/v8，准备步骤相同。
film_dir=promo/v10-en
mkdir -p "$film_dir/assets/type" "$film_dir/previews" "$film_dir/output"
swift "$film_dir/source/ExportPixels.swift" "$film_dir/assets/echo-60fps.json"
swiftc "$film_dir/source/TextRender.swift" -o "$film_dir/source/text-render"
python "$film_dir/source/make-soundtrack.py"
ffmpeg -y -i "$film_dir/source/score.wav" -af loudnorm=I=-18:TP=-1.5:LRA=8 -ar 48000 "$film_dir/source/soundtrack.wav"
python "$film_dir/source/render-film.py"             # 预览帧
python "$film_dir/source/render-film.py" --render    # 成片
python "$film_dir/source/verify-film.py"             # 媒体检查
```

英文版额外检查：

```sh
swiftc promo/v10-en/source/OCRCheck.swift -o promo/v10-en/source/ocr-check
python promo/v10-en/source/check-pixel-type.py
python promo/v10-en/source/verify-english.py
```

仓库保留英文界面的本地化素材 `v10-en/assets/blocks-en.png`；如需重新生成，可在编译文字工具后执行同版本的 `source/localize-capture.py`。完整渲染会覆盖该版本的成片。

## 素材与演示方式

基础素材来自 EchoTerm 0.10.10 的独立拍摄副本。Aurora 是拍摄专用的本地演示项目，Shell 命令真实执行。AI 文案由 `source/demo-provider.py` 提供脚本化流式回答；`read_block` 和 `jump_to_block` 仍由原应用实际执行。演示不代表真实模型的推理速度或性能。

初版窗口素材约 5 fps。后续版本复用应用像素动画代码，以 60 Hz 采样后合成像素动作、文字、镜头与转场。跨会话空间示意和飞出的像素属于功能说明动画。背景玻璃经过后期合成与调色，影片不是完整的原样屏幕录像。拍摄设置参考 `stills/settings.jpg`。

素材来自演示环境，没有采集模型密钥。临时 Provider 不写入正式应用设置。配乐与音效由各版 `source/make-soundtrack.py` 合成，没有使用外部歌曲或音频采样。
