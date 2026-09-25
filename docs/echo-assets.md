# Echo 视觉资产

2026-09-20。参考图：用户提供的 `Echo.png`（原图不随仓库分发）。仅作为角色参考，不包含软件指令。

- `Sources/EchoTerm/Resources/echo-wave.png`：使用内置 imagegen 生成的透明 PNG，保留原始 alpha；0.8 版曾用于设置导航底部和关于页面；从 0.10.2 起这些页面改用像素头像，此图仅作为旧资源保留，不再在界面展示。没有使用 CLI / API fallback。
- `Sources/EchoTerm/EchoIdentity.swift`：代码绘制的 14 × 14 像素白熊、状态动画、四趾熊爪。终端与设置头像均不依赖生成图片；完成表情只有眼睛、鼻子和外侧对勾，没有嘴巴。
- 应用只引用仓库内的图片副本，随 SwiftPM 资源包发布；无需访问生成工具的本机缓存。

## 最终生成提示词

Use case: illustration-story. Asset type: one transparent PNG mascot illustration for the settings panel of a minimal native macOS terminal named EchoTerm. Input image is character identity reference only. Create a new waist-up Echo polar bear, friendly calm smile, one large paw raised in a small hello gesture with visible charcoal paw pads. Preserve the reference's powerful stocky white/ivory polar bear, small round ears, expressive thick pale eyebrows edged with charcoal, small black eyes, large rounded black nose and broad muzzle, black scarf/cape. Simplify to a polished editorial chalk/pastel illustration with crisp readable silhouette and subtle grain; creamy fur, charcoal scarf. Center the entire upper body and waving paw with generous padding, square composition, absolutely no orange rectangle or backdrop. Actual fully transparent background outside the bear, no ground shadow, no text, no border, no other objects. Warm, confident and restrained, usable at 140 px in settings. One character, one pose.
