// moonregf：纯 MoonBit 的 Windows 注册表 hive（REGF）读写库。
//
// 读链：regf_base_block（base block 与校验和）→ regf_hbin（hbin 与 cell 头）
//       → regf_nk（键节点）→ regf_subkey_index（lf / lh / li / ri）
//       → regf_vk（值记录、内联数据、big data 分段）
// 写链：regf_builder 按同一形状把键树写回 hive，并自行计算 base block 校验和
// 文本：regt_parse 解析 .reg、regt_emit 渲染 .reg、regt_encode 处理 UTF-16LE
// 日志：regf_hvle 解析 HvLE 事务日志并按序列号把脏页重放回 hive
// 工具：bin_le 与 bin_utf16 是格式无关的字节与编码工具，regf_error 统一错误与消息
//
// 每个文件对应哪张偏移表、哪些结构只读不写，见 DESIGN.md 的「源码布局」与「REGF 字段偏移」；
// 一份真实 hive 的逐字节走查见 docs/byte-walkthrough.md。
