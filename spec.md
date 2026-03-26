# Obsidian 会议助手 Spec v0.2

## 1. 产品定位

这是一个以 **Obsidian / WalleBrain 为知识中枢** 的个人会议助手系统。

它的目标不是做一个重型会议 SaaS，而是帮助用户在 Mac 上以低复杂度完成：

1. 开会时获得大致可用的实时录写参考
2. 完整保存会议音频
3. 会后生成更准确的正式转写稿
4. 自动沉淀到 Obsidian / WalleBrain 中，形成可链接、可检索、可复盘的知识库

核心原则：

- **Obsidian / WalleBrain 是知识落地层，不是实时转录引擎**
- **实时层负责“当场可看”**
- **批处理层负责“最终更准”**
- **第一阶段优先复用系统能力，不重复造轮子**
- **所有关键产物尽量以本地文件保存**

---

## 2. 目标用户

第一阶段目标用户：

- 用户本人（单人）
- 使用 MacBook 开会
- 已经使用或愿意使用 Obsidian / WalleBrain
- 关心长期知识沉淀，重视低成本和可控性

典型场景：

- 日常内部讨论
- 产品讨论会
- 客户访谈
- 战略 brainstorming
- 个人语音记录

---

## 3. 一句话定义

**用“系统级实时 Dictation + 全量录音 + 会后 Gemini 批处理 + Obsidian / WalleBrain 落地”的方式，把会议内容变成长期可复用的个人知识资产。**

---

## 4. 核心问题

当前痛点：

1. Mac 自带 Dictation 免费可用，但作为正式稿不够稳定
2. 纯实时 API 虽可做字幕，但第一阶段为了复杂度和成本，不应自建实时 ASR 链路
3. 真正有价值的不是“当场每个字都对”，而是“会后能稳定沉淀为知识”
4. 如果会议产物不进入 Obsidian / WalleBrain，后续难以检索和复用

因此本产品解决的问题是：

**用最低复杂度把“会议当下辅助”和“会后知识沉淀”连接起来。**

---

## 5. 第一阶段产品结论

这是本版 Spec 的关键收敛：

1. **Phase 1 包含实时录写**
2. **实时录写不由 WalleBrain 自己做语音识别**
3. **实时录写采用 macOS Dictation**
4. **WalleBrain 负责启动、承载、整理、落地**
5. **正式稿以会后批处理结果为准**

换句话说：

- 开会时看到的实时字幕，是 Dictation 写进 WalleBrain 当前会议文档的内容
- 会后生成的 transcript / summary / action items，才是正式沉淀结果

---

## 6. 音频范围定义

第一阶段只考虑：

**电脑本身能够收到的声音。**

具体定义：

- 如果一段声音已经进入当前 Mac，并且 Recorder 能采到，就属于产品处理范围
- 如果声音没有进入当前 Mac，就不属于第一阶段能力范围
- 第一阶段不额外解决“外部设备上的声音如何同步进来”的问题

这意味着：

- 重点是录下当前 Mac 可获得的会议声音
- 不讨论跨设备采集
- 不讨论独立硬件录音方案

---

## 7. 用户体验主链路

### 7.1 启动方式

用户在 WalleBrain 中双击 `Ctrl`：

1. 新建一篇会议工作文档
2. 自动填入基础模板
3. 启动 macOS Dictation
4. 同时启动 WalleBrain agent
5. 开始会议录音

### 7.2 开会中

进行中的会议文档承担三种作用：

1. **实时字幕承载区**
2. **Agent 工作区**
3. **会后整理的原始上下文**

实时内容特点：

- 由 Dictation 持续写入
- 只做参考，不保证完整
- 允许有错字、漏字、断句不稳

Agent 在开会中可做的事：

- 识别这是一个会议 session
- 读取当前文档中的实时内容
- 辅助生成临时结构，例如待确认问题、临时 action items
- 但不把这些临时内容视为最终结论

### 7.3 开会后

用户结束会议后，系统：

1. 封存音频文件
2. 触发会后批处理转写
3. 生成正式 transcript
4. 生成 summary / key points / action items
5. 回写最终会议 note

---

## 8. 产品目标

### 8.1 第一阶段必须实现

- 双击 `Ctrl` 后创建会议文档
- 自动启动 Dictation，作为实时字幕来源
- 自动启动 WalleBrain agent
- 本地保存完整音频
- 会议结束后自动生成 transcript markdown
- 自动写入 Obsidian Vault 指定目录
- 自动套用会议模板
- 自动生成摘要与 action items

### 8.2 第二阶段增强

- Speaker diarization（说话人区分）
- 与项目 / 客户 / 主题笔记自动链接
- 支持标签建议
- 支持重要会议开关：决定是否调用高质量模型
- 支持会后问答（基于单场会议）

### 8.3 第三阶段探索

- 多会议聚合问答
- 会议知识图谱
- 从会议中自动抽取产品机会 / 客户反馈 / 待跟进事项
- 个人 AI Meeting Agent

---

## 9. 产品原则

1. **本地优先**：音频、markdown、元数据尽量保存在本地
2. **系统能力优先**：第一阶段先复用 macOS Dictation
3. **渐进增强**：先做主链路，再做高精度和高智能
4. **正式稿后置**：实时录写不等于最终稿
5. **结果可编辑**：Obsidian 中的最终笔记必须方便人工修改
6. **模块解耦**：热键、录音、实时显示、批处理转写、知识落地要分层

---

## 10. MVP 范围

### 10.1 必须做

#### A. 会议记录会话

- 双击 `Ctrl` 触发新会议 session
- 创建会议文档
- 自动记录会议开始时间
- 支持会议标题
- 可选字段：项目、客户、标签、重要级别

#### B. 音频录制

- 默认录制当前 Mac 可获取的会议声音
- 保存为统一格式，优先 `m4a`
- 记录会议起止时间
- 音频保存优先级高于所有其他模块

#### C. 实时录写

- Phase 1 包含实时录写
- 实时录写来源为 **macOS Dictation**
- 实时文字直接进入当前 WalleBrain 会议文档
- WalleBrain 只负责启动和承载，不自己做实时语音识别
- 实时录写允许关闭
- 不作为最终稿来源

#### D. 会后批处理转写

- 对完整录音生成正式 transcript
- 支持两档策略：
  - 普通模式
  - 重要模式

#### E. Note 生成

- 输出 markdown 文件
- 自动写入 Obsidian 指定目录
- 按模板生成结构化内容
- 支持从“临时会议文档”回写为“最终会议 note”

### 10.2 暂不做

- 自研实时 ASR 引擎
- 复杂的多人实时 speaker diarization
- 云端协作
- 团队权限
- 移动端完整支持
- 跨平台完整兼容

---

## 11. 建议技术架构

### 11.1 宿主形态

第一阶段建议做成：

**WalleBrain 内部会议工作流 + Obsidian 落地**

而不是先做成独立会议 SaaS 或重型 Obsidian 插件。

原因：

- 你已经有 WalleBrain 作为交互入口
- 双击 `Ctrl` 启动流更自然
- Dictation 与当前文档联动更直接
- 录音、Agent、文档落地可以在一个工作流里串起来

### 11.2 组成模块

#### 模块 1：Session Launcher

负责：

- 监听双击 `Ctrl`
- 创建会议 session
- 新建会议文档
- 启动 Dictation
- 启动 WalleBrain agent

#### 模块 2：Recorder

负责：

- 采集当前 Mac 可获得的会议声音
- 本地音频保存
- 会话生命周期管理

#### 模块 3：Live Note Orchestrator

负责：

- 管理实时会议文档
- 承接 Dictation 文本
- 为 Agent 提供实时上下文
- 明确标记“实时内容仅供参考”

#### 模块 4：Post Processor

负责：

- 调用批处理转写
- 生成正式 transcript
- 生成 summary / key points / action items
- 可选 speaker 分段

#### 模块 5：Obsidian Exporter

负责：

- 生成最终 markdown
- 写入 vault
- 命名文件
- 附加 frontmatter

#### 模块 6：Config Center

负责：

- Vault 路径配置
- 模板配置
- 普通 / 重要模式策略
- `DEERAPI_KEY` / `DEERAPI_BASE_URL` 相关配置复用

---

## 12. 模型与转写策略

### 12.1 总体原则

- 实时录写：**不用 Gemini**
- 实时录写：**直接用 macOS Dictation**
- 会后批处理：**用 Gemini 系列模型**

这样做的原因是：

- 第一阶段先避免自建实时 ASR 链路
- 实时层以低延迟、低复杂度为先
- 正式稿质量由会后批处理兜底

### 12.2 配置来源

- 复用 WalleBrain 当前 shell 环境中的 `DEERAPI_KEY` 和 `DEERAPI_BASE_URL`
- 第一阶段不新增独立的模型配置系统
- 模型选择由普通模式 / 重要模式决定

### 12.3 模型选择

普通模式：

- 使用 `gemini-3.1-flash`
- 目标：成本更低、速度更快、足够完成 transcript + summary

重要模式：

- 使用 `gemini-3.1-pro`
- 目标：更高质量的 transcript、summary、action items

### 12.4 策略矩阵

#### 普通会议

- 模型：`gemini-3.1-flash`
- 输出：
  - transcript
  - summary
  - key points
  - action items

#### 重要会议

- 模型：`gemini-3.1-pro`
- 输出：
  - transcript
  - summary
  - key points
  - action items
  - 可选 speaker segments
  - open questions

---

## 13. 数据与文件结构

### 13.1 推荐目录结构

```text
Vault/
  Meetings/
    2026/
      2026-03-25 产品讨论会.md
  Assets/
    MeetingAudio/
      2026/
        2026-03-25 产品讨论会.m4a
  WalleBrain/
    MeetingSessions/
      2026/
        2026-03-25 产品讨论会.session.md
        2026-03-25 产品讨论会.session.json
```

### 13.2 文件说明

`*.session.md`

- 开会期间使用的工作文档
- 承接 Dictation 实时文字
- 承接 Agent 临时分析

`*.session.json`

- 记录 session 元数据
- 包括开始时间、结束时间、音频路径、处理状态、模式档位

最终 `*.md`

- 会后正式会议 note
- 用于长期保存到 Obsidian

### 13.3 Note 命名规则

建议：

`YYYY-MM-DD 会议标题.md`

例如：

`2026-03-25 Obsidian会议助手讨论.md`

### 13.4 Frontmatter

```yaml
---
type: meeting
date: 2026-03-25
start_time: 14:00
end_time: 15:12
title: Obsidian会议助手讨论
project: Meeting Assistant
client:
importance: normal
tags:
  - meeting
  - transcript
audio_file: Assets/MeetingAudio/2026/2026-03-25 Obsidian会议助手讨论.m4a
session_file: WalleBrain/MeetingSessions/2026/2026-03-25 Obsidian会议助手讨论.session.md
processing_mode: normal
transcript_status: completed
summary_status: completed
---
```

### 13.5 Note 模板

```markdown
# {{title}}

## 基本信息
- 日期：{{date}}
- 时间：{{start_time}} - {{end_time}}
- 项目：{{project}}
- 客户：{{client}}
- 重要级别：{{importance}}
- 音频：[[{{audio_file}}]]
- Session：[[{{session_file}}]]

## 会议摘要
{{summary}}

## 关键结论
{{key_points}}

## Action Items
{{action_items}}

## Transcript
{{transcript}}
```

---

## 14. 实时录写设计

### 14.1 设计目标

- 低干扰
- 延迟低
- 启动快
- 不与正式稿混淆

### 14.2 展示规则

- 默认显示在当前会议文档中
- 最近内容持续追加
- 明确标记“实时内容，仅供参考”
- 用户可随时停止 Dictation

### 14.3 关键取舍

- 实时层不追求完美
- 实时层不单独调用 Gemini
- 第一阶段核心是“有参考可看”
- 正式记录以会后批处理为准

---

## 15. 会后整理输出

每场会议至少生成四块内容：

1. **Summary**：会议摘要
2. **Key Points**：关键结论
3. **Action Items**：待办事项
4. **Transcript**：正式转写稿

重要会议可额外生成：

5. **Speaker Segments**：发言人分段
6. **Open Questions**：未决问题

---

## 16. 状态模型

每个会议 session 至少有以下状态：

1. `created`
2. `recording`
3. `recorded`
4. `transcribing`
5. `summarized`
6. `exported`
7. `failed`

要求：

- 任一步失败都不能影响已保存音频
- 可从 `recorded` 重新触发后处理
- 可重复生成最终 note

---

## 17. 用户设置项

### 必配

- Obsidian Vault 路径
- Meetings 目录路径
- Audio 目录路径

### 可选

- 默认会议模板
- 是否默认启动 Dictation
- 默认转写档位
- 是否自动生成摘要
- 是否自动打开生成后的 note

### 高级

- 是否默认开启 WalleBrain agent
- 普通 / 重要会议默认策略

---

## 18. 非功能需求

### 18.1 性能

- 双击 `Ctrl` 后 2 秒内创建会议文档
- 录音启动响应 < 2 秒
- 结束录音后可靠保存音频
- 1 小时会议的后处理可后台完成

### 18.2 可靠性

- 即使 Dictation 失败，也不能影响录音保存
- 即使 Agent 失败，也不能影响录音保存
- 音频文件是最高优先级资产
- 批处理失败时允许重试

### 18.3 成本控制

- 默认普通会议走 `gemini-3.1-flash`
- 重要会议才切 `gemini-3.1-pro`
- 用户随时能看到本次使用的处理模式

---

## 19. 第一阶段实现建议

### Phase 1：最小可用闭环

目标：打通“实时参考 + 音频保存 + 会后沉淀”

- 双击 `Ctrl` 创建会议文档
- 自动启动 Dictation
- 自动启动 WalleBrain agent
- 本地录音
- 结束后触发 Gemini 批处理
- 自动输出 markdown 到 Obsidian

### Phase 2：增强体验

- 更好的 session 模板
- 更稳定的 action items 抽取
- 重要会议模式切换
- Speaker segments

### Phase 3：高价值增强

- 项目 / 客户自动链接
- 多会议检索和问答
- 会议知识图谱

---

## 20. 成功指标

### MVP 成功标准

- 用户能连续 7 天使用
- 每次会议都能稳定落地到 Obsidian
- 用户愿意在会后打开并编辑该 note
- 用户觉得比“只开 Dictation 不整理”更有价值

### 质量指标

- 音频保存成功率接近 100%
- Note 生成成功率 > 95%
- 用户主观满意度：会后整理效率明显提升

---

## 21. 明确不做什么

第一阶段不追求：

- 自研实时语音识别系统
- 替代专业会议 SaaS
- 完美实时 speaker diarization
- 团队级协作后台
- 重型云端数据库系统
- 复杂权限管理

我们做的是：

**一个属于个人的、低复杂度的、依托 WalleBrain 与 Obsidian 持续沉淀会议知识的助手。**
