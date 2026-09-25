# EchoTerm 0.8 设计

## 同一条终端内容流

每个会话中的命令与 AI 问答统一为 Block。命令保留目录、输入、输出、退出状态、耗时和来源；AI Block 保留问题、流式回答、工具步骤和完成状态。输入位于最后一个 Block 中，随内容滚动，不固定在窗口底部。

点击或 hover 可切换区块阅读状态，整行细线分隔内容。命令后的快判按钮横向排列，较窄面板可横向滚动；点击会在末尾创建 AI Block，源命令上下文保持正确。旧的已完成选项不会被新命令覆盖，未完成的过期请求会取消。

## 命令与聊天的分流

输入默认跟随所属标签（新安装初始为自动识别），Return 前显示“执行命令”或“发送给 Echo”。当前 Shell 的 precmd / PROMPT_COMMAND 将 PATH、内建命令、alias 和函数名称写入会话私有临时目录。应用在后台构建可执行文件索引，并在每次 Shell 返回提示符后刷新。

词法分析识别引号、转义和前置变量赋值，不执行输入、不展开命令替换。已知命令名显示绿色；未知名称显示红色，Return 转交 AI。变量、函数定义、重定向及已识别复合语法交给 Shell 解析。这里只判断命令入口，参数与完整语法由 Shell 最终检查。

原生下拉可临时选择终端或 AI，也可跟随标签默认值；⌘Return 强制执行，⌥Return 强制提问。模型工作时再次提问会保留输入并提示停止或等待，不丢弃草稿。自主模式运行期间锁定其所属终端输入。

灰字补全以最近命令历史优先，结合命令索引和文件路径；文件名中的空格和 Shell 特殊字符会转义。↑↓ 连续选择，Tab 接受；候选不会进入实际输入，只有接受才写入。处理中文输入法 marked text 时暂停快捷键接管和着色。没有候选时上下键回看本会话命令历史，不混入 AI 问题。尚未执行第三方 zsh 参数补全插件。

## 内联 AI 与 Markdown

Echo 白熊限定在每段 AI 回答左侧。14 × 14 代码像素矩阵保留奶白毛色、点状眼睛、黑鼻子和方块圆耳。思考中像素依次离开熊脸、合成流动光点，再复原；文字输出伴随底部打字光点；真实 PTY 执行时角落的像素命令符号依次亮起；完成时微跳、笑脸与对勾；错误和停止分别显示提醒和休息表情。状态直接来自请求活动和 PTY 所有权，不解析状态文本。历史回答保存本轮最终表情，不被新一轮模型状态覆盖。

持续动画仅用于活动头像，完成动效短暂播放后暂停；系统减少动态效果时保留静态表情并关闭光点闪动。设置、关于页使用透明的 Echo 挥手插画，导航入口、快速意图和标签设置使用小熊爪。插画保存在应用资源包，详情见 echo-assets.md。

Markdown 使用原生 SwiftUI 渲染标题、段落、行内强调与代码、列表、引用、代码围栏、表格和链接。流式未闭合代码围栏仍作为代码呈现；代码块可复制，Shell 代码可填入终端后再执行。不会加载远端图片或执行 HTML；链接限制为 http、https 和 mailto。

问答模式不提供执行工具，客户端也拒绝意外返回的工具调用。自主模式允许完整工具参数在当前 PTY 执行，再回传输出、目录和退出状态。AI 回答和 Shell 命令分别使用稳定 Block ID；即使手动命令运行中插入 AI Block，也不会把命令输出写进错误的区块。停止只中断当前助手持有的命令。

## 时间轴与辅助对话

右侧居中悬浮短轨采用固定 17 pt 节点间距，短历史不撑满窗口；轨道最多 320 pt，并适应窄小分屏。长历史在轨道内部滚动，每个区块都有独立节点。命令为圆点，AI 为圆角方点，失败为橙色，当前节点加细环。指针按高斯距离连续放大附近节点，弹簧同时插值位置和强度；进入轨道时从当前位置展开，离开时原地恢复。半透明材质预览包含序号、类型、时间、输入开头及两行输出，限制在当前面板边界内。点击或拖动释放后跳到对应 Block。支持辅助功能增减操作，以及系统减少动态效果设置。

主流程不再自动弹出浮层。标题栏或 ⌘J 可以打开常驻辅助对话，跨标签保留所属会话、未发送草稿及历史。点击外部不会消失，最小化按钮或快捷键收起。模式切换采用统一紧凑组件，问答与自主操控都有图标、选中背景和说明。

## 执行与存储边界

保持每面板一个真实 Bash / Zsh PTY。自绘输入写入 0600 临时文件，在原 Shell 中执行，保留 cwd、变量、alias 和函数；交互程序需要时切换 SwiftTerm 视图。普通输出以 75 ms 合并，归档最多 160,000 字符，滚动缓存 5,000 行；每会话保留最近 300 个已完成区块和未完成任务。

Provider、密钥、思考强度、主题等设置延续原有存储。布局、进程、区块与对话仍在内存，退出不恢复。快速意图使用独立模型选择、关闭思考、512 token 上限与 8 秒截止，不能调用工具。关闭上下文同时停止自动快判。三种 API 协议、取消保护、超时和自主执行步数限制保持有效。


## 标签模式与名称

每个 WorkspaceTab 保存默认输入路由和 AI 模式，创建分屏时复制到新会话，修改标签默认时同步已有分屏。每个输入 Block 的 override 可为空，空值表示继承标签；成功提交后清除 override，拒绝提交或忙碌时保留。AI 运行捕获发起时的模式并写入 Block，修改标签默认值只影响后续输入，切换当前任务到问答则明确取消该会话的自主运行。

输入方式使用 AppKit NSPopUpButton，选项在第一层直接呈现，不再用 SwiftUI Menu 包裹 Picker。标签设置同时提供重命名、输入默认和 AI 默认，顶部标签也有同样的右键入口。

自动名称由最新区块所在会话的目录、所有分屏中最近执行的命令或 AI 概括产生。自定义名称始终优先；清空后恢复自动规则。关闭分屏后重新从剩余区块计算名称。全局新标签默认值和命名规则持久化，现有标签实例仍跟随现有的内存生命周期。

AI 名称按标签隔离，近期最多 5 个输入，每条输入最多 500 字符、命令结果最多 400 字符，应用已有脱敏。请求 debounce 700 ms，重复上下文去重，使用快速 Provider / 模型、关闭思考、96 token 输出和 8 秒独立截止。自定义名称、切换命名规则、关闭上下文和关闭标签取消任务；晚到结果不能覆盖手动名称，失败保留已用名称并在标签提示中记录原因。

## 工具调用中的回答顺序

每轮模型返回的可见文本归属独立 ChatMessage 与 AI Block，工具步骤元数据保留在发起调用的段落。终端内容流直接显示真实命令 Block 的输出，避免重复渲染工具卡片。开始工具命令时，在它下方新建活动回答段落；一轮内多个工具调用移动尚未输出文字的占位段到结果下方。下一轮流式文字只更新这个新段落。

显示顺序为「问题和首段回答 → 命令/结果 → 后续回答 → 命令/结果 → 最终总结」。所有段落使用相同运行 ID、各自消息 ID；异步回调同时核对运行和活动段落。取消时只中断所属命令，关闭当前段落的流式状态并退役所有未完成工具步骤。模型 wire history 仍沿用供应商原生工具续接格式，不因显示拆段丢失 reasoning / tool IDs。


## Token 用量与整轮计时（0.9）

每个 AITransport 请求由统一 recorder 包裹，以 UUID 去重。SSE usage 是累计快照，覆盖同一请求已知字段；请求结束记录一次，全局账本涵盖对话/自主操作、快速意图、自动标签命名与连接测试。整轮 meter 横跨工具循环，包含中间请求、最终总结与真实 Shell 等待时间，只有最后一段 ChatMessage 关联 roundSummary。失败或主动停止显示已知部分，未返回值保持 nil，部分汇总用 + 标记，不推算或伪造 0。

Chat Completions 请求 stream_options.include_usage，解析 choices 为空的最终用量事件；旧兼容网关可手动关闭。Responses 读取 response.completed.response.usage，Claude 合并 message_start 与 message_delta 的累计字段。OpenAI cached/reasoning 都是子项；Claude 基础 input_tokens 加 cache_read_input_tokens 与 cache_creation_input_tokens 后才是总输入。实际模型名按快速配置或对话配置捕获。

协议依据：[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)、[Claude 流式消息](https://platform.claude.com/docs/en/build-with-claude/streaming)、[Claude 提示缓存](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)。

账本为 Application Support/EchoTerm/Usage/events.jsonl，逐请求追加并同步，不含提示词、输出、命令或 API Key；QA Bundle 使用独立目录。损坏行会被跳过并在设置中提示，同时保留原文件。记录按请求开始时的本地时间归档；周一为周起点；边界采用 [start, end)，随日历处理夏令时。全局总计覆盖全部历史，趋势图总计页展示最近 12 个月；无返回计数不混作 0。统计从升级版本后首次请求开始，不回填旧历史，也不能统计独立 CLI 或其他应用的调用。

配色保留三个原始枚举值以兼容已有偏好，新增雾蓝、鸢尾、琥珀、暖瓷。全部 SwiftUI 表面采用主题背景/正文/次级文字/强调色；原生 SwiftTerm 交互视图使用成套 16 色 ANSI 调色板。编辑器命令有效性、错误和成功提示继续使用语义颜色。


## 滚动性能与控件（0.9）

在独立 QA 窗口实际复现持续主线程布局循环：采样显示 SwiftUI GraphHost.runTransaction → NativeChoicePicker.updateNSView / InlineCommandEditor.updateNSView 持续更新，CPU 约 99%，内存增长至约 1.6 GB。字体、颜色、controlSize、文本属性在没有变化时仍重复赋值，触发 AppKit intrinsic layout invalidation；区块几何反馈又重建父视图。修复输入框样式只在文本/字体/颜色/命令判断变化时更新，几何反馈只在可见区块真的变化时写状态；NSPopUpButton 随后按用户新要求全部替换为自绘选项菜单。

文本视口使用 NSTextStorage / NSLayoutManager 的 allowsNonContiguousLayout，只对可见区域排版；超过 4 KB 或 20 行的输出与长命令限制显示高度，完整文本可滚动选择。长输入测量不再 ensureLayout 整个文本容器；4 KB 以上草稿暂停灰字候选计算，但完整命令仍可编辑和执行。ShellWords.executable 找到可执行词后停止，不扫描巨大参数。Markdown 解析在后台任务中进行，滚动/主题更新复用解析结果；100 KB 以上 AI 文本使用明确标注的完整原文视图，避免大量 SwiftUI 富文本节点阻塞。

EchoControls 使用纯 SwiftUI 绘制样式，AnchorPreference 将下拉/右键菜单呈现在根视图内，不依赖系统 NSPopUpButton / NSMenu 外观，也不受内部 ScrollView 裁切。菜单支持键盘选择、Esc 和外部点击关闭、焦点恢复。窗口、输入法、文本选择、辅助功能和 macOS 全局菜单栏仍使用系统基础能力。设置切页重置滚动位置。

背景不透明度范围 0.1...1，旧值兼容并钳制非法值。毛玻璃用 NSVisualEffectView 三种材质实时合成；材质自身具有系统定义的模糊与染色，不把改变 opacity 伪装成 blur radius，不使用私有 CABackdropLayer 或采集用户桌面。依据：[Apple NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview) 及本机公开 AppKit SDK 头文件。
