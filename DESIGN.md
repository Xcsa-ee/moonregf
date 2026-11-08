# 设计说明

moonregf 是纯 MoonBit 实现的 Windows 注册表 hive 文件（REGF）读取与写入库：不调用 Windows API、不链接 C 库、不使用 FFI，因此能在 wasm-gc 与 js 后端直接解析 hive 文件。

## 分层

| 文件 | 职责 |
| --- | --- |
| `bin_le.mbt` | 小端 16 / 32 位读取 |
| `regf_base_block.mbt` | 4096 字节 base block：签名、序列号、版本、文件类型、根 cell、bins 大小、UTF-16LE 文件名、XOR 校验和 |
| `regf_hbin.mbt` | cell 头：分配位、载荷长度、越界校验 |
| `regf_nk.mbt` | 键节点（nk）：flags、父键、子键数与列表、值数与列表、类名、压缩与 UTF-16 名称 |
| `regf_subkey_index.mbt` | 子键索引 lf / lh / li / ri（ri 递归展开）与键树遍历 |
| `regf_vk.mbt` | 值记录（vk）、值列表、inline 数据、big data 分段、类型映射与访问器 |
| `regf_hvle.mbt` | 事务日志（`.LOG1` / `.LOG2`）HvLE 条目解析与脏页重放 |
| `regf_builder.mbt` | `HiveBuilder`：从键树生成 base block、hbin、nk / vk / lf、值列表与数据 cell |
| `regt_encode.mbt` `regt_parse.mbt` `regt_emit.mbt` | `.reg` 文本的 UTF-16LE 编码、解析与渲染 |
| `regf_error.mbt` | 统一的错误类型与消息 |
| `cmd/main` | 命令行：查看文件头与键树、导出值、生成 hive、`.reg` 导入导出、日志重放 |
| `examples/basic` | 不需要输入文件的最小可运行示例 |

## 关键判断

1. **格式判断不依赖字符串解码。** wasm-gc 后端下 `Bytes::to_unchecked_string` 不是 UTF-8 解码，而是把字节按 UTF-16 码元重解释，四个签名字节会被读成别的字符。因此签名按字节比较，文本解码统一走 `@utf8.decode_lossy`。
2. **big data 每段最多 16344 字节。** 段 cell 的长度按 8 字节对齐，多出来的是填充；按最小者截断，否则段边界会错位。
3. **值列表按 nk 的 `value_count` 截断。** 值列表 cell 同样 8 字节对齐，尾部可能残留旧偏移；本机 `NTUSER.DAT` 有 67 个键命中这类残留，多读会产生孤儿值。
4. **HvLE 条目按实测布局解析。** 条目大小在 `+0x04`、序列号在 `+0x0C`、bins 大小在 `+0x10`、脏页数在 `+0x14`、页引用从 `+0x28` 开始；前进用条目自带的大小字段，不重新推算。
5. **写入器只做精确布局。** cell 大小按 8 字节对齐，值不超过 4 字节时内联；超出单个值 cell 与删除段写成明确的错误，而不是静默截断。

## 参考与来源

- **格式依据**：Windows 注册表 hive 的二进制格式（REGF base block、hbin、nk / vk / sk / lf / lh / li / ri 记录、big data、事务日志 HvLE）与 `.reg` 文本格式按公开格式说明实现，未移植任何上游源码。
- **测试对拍（仓库外）**：`reg.exe`（Windows 自带导出与查询）与 regipy 6.5.0（Apache-2.0）只在本机作为独立解析器使用，不进入仓库、不作为运行依赖、不复制其代码。
- **测试素材**：全部由测试代码在内存中构造；对拍用的真实 hive 取自本机系统文件副本，不进入仓库。
- **未包含**：任何 C / C++ / Python 注册表库的源码、Windows SDK 头文件、符号表或反编译产物。
- **许可证**：本项目 Apache-2.0，全文见 `LICENSE`。

## 开发方式

先按格式说明写规格（字段偏移、校验方式、错误分类），再落实现与白盒测试；每层完成后用真实 hive 与独立解析器双向对拍，全绿才提交。CI 覆盖格式检查、`moon check --deny-warn`、构建、wasm-gc 与 js 两个后端的测试，以及可运行示例。实现的起草与审查使用 AI 辅助，规格、对拍数据与验收结论由本人在本机逐条复现确认。

## REGF 字段偏移（实现与测试共用的唯一口径）

偏移从各记录的签名起算；cell 里的记录从 payload 起点起算，payload 起点 = hbin 起点 + 4 字节 cell 头。

### base block（文件前 4096 字节）

| 偏移 | 宽度 | 内容 |
| --- | --- | --- |
| 0x00 | 4 | 签名 `regf` |
| 0x04 | 4 | 主序列号 |
| 0x08 | 4 | 次序列号 |
| 0x0C | 4 | 最后写入时间低 32 位 |
| 0x10 | 4 | 最后写入时间高 32 位 |
| 0x14 | 4 | 主版本（1） |
| 0x18 | 4 | 次版本（5 或 6） |
| 0x1C | 4 | 文件类型：0 主文件、1 旧式日志、6 新式日志 |
| 0x20 | 4 | 文件格式（1） |
| 0x24 | 4 | 根键 cell 偏移（相对 bins 起点） |
| 0x28 | 4 | bins 数据长度 |
| 0x2C | 4 | 簇因子 |
| 0x30 | 64 | 文件名（UTF-16LE，32 个码元） |
| 0x1FC | 4 | 校验和 = 前 508 字节按小端 u32 逐字异或 |

### hbin 与 cell 头

| 位置 | 宽度 | 内容 |
| --- | --- | --- |
| hbin + 0x00 | 4 | 签名 `hbin` |
| hbin + 0x04 | 4 | 相对第一个 hbin 的偏移 |
| hbin + 0x08 | 4 | 本 hbin 总长度（4096 的整数倍） |
| cell + 0x00 | 4 | 有符号长度：负数=已分配、正数=空闲；含这 4 字节，按 8 字节对齐 |

### nk（键节点，偏移从 `nk` 签名起算）

| 偏移 | 宽度 | 内容 |
| --- | --- | --- |
| 0x02 | 2 | flags；bit 0x20 = 名称按单字节存放 |
| 0x10 | 4 | 父键 cell 偏移 |
| 0x14 | 4 | 子键数 |
| 0x1C | 4 | 子键列表 cell 偏移 |
| 0x24 | 4 | 值数 |
| 0x28 | 4 | 值列表 cell 偏移 |
| 0x2C | 4 | 安全描述符 cell 偏移 |
| 0x30 | 4 | 类名 cell 偏移 |
| 0x48 | 2 | 名称字节数 |
| 0x4A | 2 | 类名字节数 |
| 0x4C | n | 名称本体 |

### vk（值记录，偏移从 `vk` 签名起算）

| 偏移 | 宽度 | 内容 |
| --- | --- | --- |
| 0x02 | 2 | 名称字节数 |
| 0x04 | 4 | 数据长度；最高位为 1 表示数据就在下面 4 字节内联 |
| 0x08 | 4 | 数据 cell 偏移，或内联的 4 字节数据 |
| 0x0C | 4 | 类型码（REG_SZ=1、REG_DWORD=4、REG_MULTI_SZ=7、REG_QWORD=11） |
| 0x10 | 2 | flags；bit 0x01 = 名称按单字节存放 |
| 0x14 | n | 名称本体 |

### 子键索引与大数据段

| 记录 | 布局 |
| --- | --- |
| `lf` / `lh` | 0x02 起 2 字节条目数；0x04 起每条 8 字节：nk 偏移 + 名称提示（lf）或哈希（lh） |
| `li` | 0x02 起 2 字节条目数；0x04 起每条 4 字节 nk 偏移 |
| `ri` | 0x02 起 2 字节条目数；0x04 起每条 4 字节，指向下一层 lf / lh / li |
| `db` | 0x02 起 2 字节段数；0x04 起每段 4 字节 cell 偏移，每段最多 16344 字节数据 |

### HvLE（事务日志条目）

| 偏移 | 宽度 | 内容 |
| --- | --- | --- |
| 0x00 | 4 | 签名 `HvLE` |
| 0x04 | 4 | 本条总长度，按 512 字节对齐；前进用它，不要自己重算 |
| 0x0C | 4 | 序列号 |
| 0x10 | 4 | 对应 hive 的 bins 数据长度 |
| 0x14 | 4 | 脏页数 |
| 0x28 | 8 x n | 每条脏页引用：相对 bins 起点的偏移 + 长度 |


## 源码布局

前缀说明：`regf_` 是 hive 二进制侧（一条记录一个文件），`regt_` 是 .reg 文本侧，`bin_` 是与格式无关的字节与编码工具。

| 文件 | 对应结构 | 偏移口径 |
| --- | --- | --- |
| `bin_le.mbt` | 小端 u16 / u32 读取 | 无 |
| `bin_utf16.mbt` | UTF-16LE 与单字节名称解码 | 无 |
| `regf_error.mbt` | 错误类型与消息 | 无 |
| `regf_base_block.mbt` | base block | 本文件 base block 表 |
| `regf_hbin.mbt` | hbin 与 cell 头 | hbin 与 cell 头表 |
| `regf_nk.mbt` | nk 键节点 | nk 表 |
| `regf_subkey_index.mbt` | lf / lh / li / ri | 子键索引与大数据段表 |
| `regf_vk.mbt` | vk 值记录 | vk 表 |
| `regf_hvle.mbt` | HvLE 事务日志 | HvLE 表 |
| `regf_builder.mbt` | 写入器 | 由上面各表共同约束 |
| `regt_encode.mbt` | .reg 的 UTF-16LE 编码 | 无 |
| `regt_parse.mbt` | .reg 解析 | 无 |
| `regt_emit.mbt` | .reg 渲染 | 无 |
| `cmd/main` | 命令行 | 无 |
| `examples/basic` | 最小示例 | 无 |
