# 设计说明

moonregf 是纯 MoonBit 实现的 Windows 注册表 hive 文件（REGF）读取与写入库：不调用 Windows API、不链接 C 库、不使用 FFI，因此能在 wasm-gc 与 js 后端直接解析 hive 文件。

## 分层

| 文件 | 职责 |
| --- | --- |
| `le.mbt` | 小端 16 / 32 位读取 |
| `header.mbt` | 4096 字节 base block：签名、序列号、版本、文件类型、根 cell、bins 大小、UTF-16LE 文件名、XOR 校验和 |
| `cell.mbt` | cell 头：分配位、载荷长度、越界校验 |
| `key.mbt` | 键节点（nk）：flags、父键、子键数与列表、值数与列表、类名、压缩与 UTF-16 名称 |
| `subkey.mbt` | 子键索引 lf / lh / li / ri（ri 递归展开）与键树遍历 |
| `value.mbt` | 值记录（vk）、值列表、inline 数据、big data 分段、类型映射与访问器 |
| `log.mbt` | 事务日志（`.LOG1` / `.LOG2`）HvLE 条目解析与脏页重放 |
| `writer.mbt` | `HiveBuilder`：从键树生成 base block、hbin、nk / vk / lf、值列表与数据 cell |
| `reg_text.mbt` `reg_parse.mbt` `reg_export.mbt` | `.reg` 文本的 UTF-16LE 编码、解析与渲染 |
| `error.mbt` | 统一的错误类型与消息 |
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
