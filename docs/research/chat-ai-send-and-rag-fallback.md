# Chat AI 发送交互与 RAG 无来源回退方案

## 结论

建议先做最小且稳健的方案：用户点发送后立即清空输入框并显示用户气泡，同时添加 `Thinking…` 助手占位。如果检索无匹配，将占位替换为“没有在 transcript 中找到依据”，并提供明确的「用 AI 常识回答」操作；该类回答始终显示 `No transcript source` 标签。第一版不需要 token streaming。

## 一手资料观察

- 生成中需要明确可见的状态。OpenAI 把 `Thinking…/Generating…/Working…` 列为用户可见的生成状态，并提供 `Stop generating` 和 `Regenerate`；Claude 的 Extended Thinking 显示 Thinking 指示器和计时器。[OpenAI 故障排查](https://help.openai.com/en/articles/7996703) [Anthropic Extended Thinking](https://support.anthropic.com/en/articles/10574485-using-extended-thinking)
- Apple 的 HIG 要求用进度指示器告知用户 App 没有卡住；如果中断没有负面后果，应允许取消。[Apple Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- Streaming 可边生成边展示，适合 chatbot 的快速交互；但“先显示用户轮次和占位”不依赖 streaming，一次性模型调用也能做。[Gemini 文本生成文档](https://ai.google.dev/gemini-api/docs/text-generation)
- 错误和重试应属于已发送的轮次。OpenAI 在生成失败后提供 `Regenerate`，Gemini 也允许重新生成最近的回答。[OpenAI 故障排查](https://help.openai.com/en/articles/7996703) [Gemini 重新生成回答](https://support.google.com/gemini/answer/14262426)
- 检索到内容不等于回答有依据。Google 明确说明，来源相关性低或信息不完整时，回答可能没有 grounding metadata，此时回答不是 grounded。[Google Cloud grounding 响应说明](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/grounding/grounding-with-vertex-ai-search)
- 严格 grounded 助手应在上下文不包含答案时明确说信息不可用，而不是用模型常识补齐。[Gemini 严格 grounded prompt 指南](https://ai.google.dev/gemini-api/docs/prompting-strategies)
- 来源状态应让用户可见。ChatGPT Search 显示 inline citations 和 Sources 面板；Gemini 的 grounding API 也将文本片段与来源注解关联。[ChatGPT Search](https://help.openai.com/en/articles/9237897-chatgpt-search) [Gemini grounding citations](https://ai.google.dev/gemini-api/docs/google-search)

## 当前问题

当前 `AskView.ask()` 在获得成功答案后才清空 `question`。检索为空时，它只在 composer 上方显示错误，问题仍留在输入框。这使“已发送”与“未发送草稿”的状态混在一起。

## 方案比较

| 方案 | 发送后 | 无来源时 | 优点 | 代价 / 风险 |
|---|---|---|---|---|
| A. 严格 transcript | 立即显示用户气泡 + `Thinking…` | 助手气泡明示无依据，提供「编辑问题」和「扩大范围」 | 最安全，不会把常识冒充成记录 | Ask AI 已经是全 App 范围，扩大范围对其无效 |
| B. 显式可选降级（推荐） | 同 A | 先明示无依据，再提供「用 AI 常识回答」；结果标记 `No transcript source` | 不卡 composer；用户主动选范围；既安全又有用 | 需要一个无证据模式和持久的来源状态 |
| C. 自动降级到常识 | 同 A | 检索为空就直接用模型知识回答 | 操作最少 | 用户容易把未 grounded 回答误认为 transcript 事实，不建议 |

## 推荐交互

1. 点发送后立即捕获 trimmed question，清空 composer，在列表中插入用户气泡。
2. 紧接着显示助手占位 `Thinking…`；发送键可在生成时变为 Stop，若现有引擎不能安全取消，第一版只禁用二次发送。
3. 成功时用真实答案替换占位，显示 `Based on N transcript excerpts`。
4. 无匹配时用助手气泡替换占位：“我没有在这些 transcript 中找到足够依据。”下方显示「用 AI 常识回答」和「编辑问题」。Thread/Workspace Ask 可再加「扩大范围」；Ask AI 不显示该项。
5. 模型错误时在该助手气泡显示错误和「重试」，不把原问题放回 composer。

## 最小交付边界

第一版只需要本地 pending turn 状态、立即清空 composer、一个占位气泡，以及无来源/错误的轮次内操作。先不做 token streaming、多请求并发、网络搜索或复杂的检索置信度 UI；它们只在本地模型引擎提供相应能力后再加。
