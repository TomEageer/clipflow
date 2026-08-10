# Clipflow

macOS 剪贴板管理器。原生 Swift，架构自由度 / 性能 / 拓展性优先。

> 工作代号，正式名待定。当前进度：**M1 完成**（已能真正记录剪贴板）。

## 现在能干什么

```bash
swift build -c release

.build/release/clipflow seed 2000       # 灌测试数据
.build/release/clipflow list -n 10      # 列出最近
.build/release/clipflow search 分布式锁   # 中文全文检索
.build/release/clipflow show 42         # 看某条的全部 representation
.build/release/clipflow stats           # 存储统计 + 权限自检
.build/release/clipflow bench 50        # 性能基准（对照预算断言）
.build/release/clipflow watch           # 开始记录剪贴板（M1）
.build/release/clipflow poll 10         # 同步轮询 10s（调试用）
.build/release/clipflow optimize        # 合并 FTS 段 + 回收空间
```

`--root <路径>` 可指定数据目录，默认 `~/Library/Application Support/Clipflow`。

## 架构

```
ClipflowCore     核心引擎 —— 零 UI 依赖，可被 App / CLI / 未来任何 Shell 复用
ClipflowCapture  捕获层 —— 唯一允许 import AppKit 的非 UI 目标（NSPasteboard 在 AppKit 里）
ClipflowCLI      命令行客户端 —— 不是附赠品，是「Core 真的解耦」的强制验证
```

**呈现层与核心彻底解耦**：CLI 能跑通就证明 Core 没偷偷依赖 UI。有一条测试硬性禁止 `ClipflowCore` 出现 `import AppKit / SwiftUI / UIKit / VisionKit`。

### 存储

| 文件 | 内容 |
|---|---|
| `clipflow.sqlite` | 内容库：items + representations |
| `clipflow-index.sqlite` | **索引库（独立文件）**：FTS5 + OCR 结果 + OCR 队列 |
| `blobs/` | 内容寻址存储（CAS），SHA-256 两级分桶，天然去重 |

目录 `700`、库文件 `600`。（竞品 Paste 实测是 `644`，同机任意用户可读。）

### 几条被实测逼出来的硬规则

| 规则 | 依据 |
|---|---|
| **禁止 `ORDER BY rank`**，一律 `rowid DESC` | 2 万条命中时 rank 要 46ms，rowid DESC 只要 0.30ms —— **快 150 倍**；且剪贴板用户要的本就是"最近的"不是"最相关的" |
| FTS5 必须 `detail=full` | 只有它支持短语查询。中文 bigram 检索退化成 AND 匹配会让精度崩掉 |
| 中文走**应用层 bigram 分词** | FTS5 自带 unicode61 把连续汉字当一个词元，搜"订单"匹配不到"订单支付回调" |
| 压缩阈值 **512B** | 实测 120B 短文本压完仍 97.5%，纯白费 CPU |
| 图片必须 **TIFF → PNG 转码** | 剪贴板给的 TIFF 是 235MB，PNG 只要 12.45MB（**5.3%**） |
| 文件只存引用 | 剪贴板对 200MB 视频只给 **76 字节**路径，文件内容从不进剪贴板 |
| **读取绝不异步延后** | 剪贴板内容瞬态，延后读会张冠李戴。宁可漏，不可错 |

有两条写成了测试：`ORDER BY rank` 禁令、Core 零 UI 依赖。会随 CI 一起跑。

## 实测性能（4.8 万条，M4 Pro）

| 项 | 中位 | P95 | 预算 |
|---|---|---|---|
| 列出最近 20 条 | 0.09 ms | 0.11 ms | — |
| 中文短语检索 | 0.16 ms | 0.19 ms | 16 ms |
| 标识符检索 | 0.45 ms | 0.55 ms | 16 ms |

存储：4.8 万条 = 47.6 MB（内容库 35.6 MB + 索引库 12 MB）。
`bench` 子命令会对照预算给 ✅/❌，可直接接进 CI。

## 测试

```bash
swift test    # 33 个测试，7 个套件
```

覆盖：中文分词、LZFSE 压缩往返、CAS 去重与分桶、**多 representation 全量保真往返**、内容去重、短语查询防误报、密码管理器内容拦截、敏感内容不入索引、文件引用只存路径、库文件权限、以及两条架构约束。

## 已知限制

- **入库吞吐 2716 条/s**：每条一个事务 + 一次去重查询。真实剪贴板负载是每天几百条（差 3 个数量级，够用），但**做导入/迁移功能时需要改批量事务**。
- 加密尚未实现，D4 的 blob 加密与主库加密方案见 `docs/01 §5`。
- OCR 原型在 `prototype/OCRProcessor.swift`，尚未接进管道（排在 M4）。

## 路线

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | Package 切分 + GRDB schema + migrator + CLI | ✅ **完成** |
| **M1** | 剪贴板捕获：轮询 + 全 representation + concealed 过滤 | ✅ **完成** |
| M2 | 检索完善 + 性能 CI 断言 + SQLCipher 决策闸门 | |
| M3 | 热键 + 鼠标旁面板 + 焦点恢复 + CGEvent 粘贴 | |
| M4 | Transform 链 + PasteProfileLearner + 图片 OCR | |
| M5 | 扩展契约 + 设置界面 + 签名分发 | |

## 文档

| 文件 | 内容 |
|---|---|
| `docs/00-架构设计.md` | 分层、注册点、决策 D1–D7、性能预算、里程碑 |
| `docs/01-存储分级与规模.md` | 百万条压测、内容分级、加密三级、竞品实证 |
| `docs/03-图片OCR设计.md` | Vision / VisionKit 实测、切块方案、静默失效防线 |
| `docs/04-剪贴板捕获.md` | 轮询、18.5 秒阻塞坑、同步读取的取舍 |
| `bench/` | 全部基准脚本，可重跑复现文档里的每个数字 |

文档里查不到、没验证的一律标 `[未能确认]` / `[待验证]`，不拿猜测当结论。
