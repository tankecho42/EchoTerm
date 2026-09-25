# EchoTerm · Lightfield

30 秒浅色版产品宣传片。1920 × 1080，60 fps，H.264 + AAC。

成片：`output/EchoTerm-Promo-v2-30s.mp4`

## 画面

- 浅色摄影棚背景，雾蓝玻璃窗口，柔和背景窗与反射。
- Echo 的像素从真实界面标题栏飞出，组成「块」字；继续飞进 AI 回答区；最后成为 EchoTerm 字标的 E。
- 四次整幅旋转转场，配合透视旋转、近景与远景转换。
- 跨会话部分固定在同一空间：S2 提问 → 拉远显示两个会话 → 像素查找 S1 → 读取 Block 03 → 原始配置 Block 推近并高亮两次 → 拉远回到完整关系。

| 时间 | 镜头 |
| --- | --- |
| 00:00–00:05.5 | 终端近景拉远；Block 边界；像素组成标题 |
| 00:05.5–00:11.2 | 输入问题；Echo 接收、思考、流式回答、完成 |
| 00:11.2–00:21.7 | 连贯的跨 Session / Block 查找与定位 |
| 00:21.7–00:25.8 | 玻璃材质与背景窗口，远景环绕 |
| 00:25.8–00:30 | 像素组成品牌字标；Echo 出场、眨眼 |

## 素材与真实性

本片为**真实界面素材与产品动效的合成**，不是一镜到底的原始屏幕录像。

- 产品界面来自 EchoTerm 0.10.10 的本地录制素材，录制配置为 **雾蓝 / 25% 背景不透明度 / 通透毛玻璃**。隔离窗口截图不含桌面背景，因此毛玻璃背景和光照在后期合成。
- 命令记录、配置输出、测试结果的图层取自 `../stills` 和 `../footage`。AI 回答放大镜头重排了同一份演示文案，以保证字体清晰和流式显示流畅；空间中的 S2 提问面板也为说明动画重新排版。
- Echo 像素运动直接复用 `Sources/EchoTerm/EchoIdentity.swift` 的图形与插值代码，由 `source/ExportPixels.swift` 以 60 Hz 确定性采样，不重复播放上一版低采样率录屏中的头像动画。
- 飞出界面的粒子、立体会话地图、文字放大标注、相机运动均属于宣传片说明动效，不是软件中新增的 UI 控件。
- 跨会话工具确实在录制时执行过：读取 S1 / Block 03，得到 `port = 4317`，随后跳转并高亮。审计记录在 `../source/demo-audit.jsonl`。AI 演示使用本地脚本化 Provider，不代表真实远程模型的推理速度或性能测试。
- 音乐与音效由本项目合成器生成，无外部商用音乐或音频素材。配乐约 -18 LUFS，峰值限制 -1.5 dBTP。
- 本轮仅更新宣传片文件，未修改或重启用户日常使用的 EchoTerm。

## 可编辑源文件

- `source/render-film.py`：图层、镜头、粒子路径、字幕、合成、编码。
- `source/ExportPixels.swift`：与应用相同的像素图形、表情、流动插值、双环与直接眨眼。
- `source/TextRender.swift`：macOS 原生字体离屏渲染。
- `source/make-soundtrack.py`：原创配乐及时间点音效。
- `assets/echo-60fps.json`：全片 1800 帧的原生像素状态。
- `previews`：关键帧、构图检查及编码后检查。

## 重新渲染

需要 macOS、Swift / AppKit、Python 3 + Pillow / NumPy / OpenCV、FFmpeg。
此工作区的 Python 依赖在 Codex runtime 中，OpenCV 安装在 `/tmp/echoterm-video-python`。

```sh
swift promo/v2/source/ExportPixels.swift promo/v2/assets/echo-60fps.json
swiftc promo/v2/source/TextRender.swift -o promo/v2/source/text-render
python3 promo/v2/source/make-soundtrack.py
ffmpeg -y -i promo/v2/source/score.wav -af loudnorm=I=-18:TP=-1.5:LRA=8 -ar 48000 promo/v2/source/soundtrack.wav
python3 promo/v2/source/render-film.py --render
```

只生成关键帧时，省略 `--render`。素材目录相对于脚本解析，执行位置不影响渲染。
