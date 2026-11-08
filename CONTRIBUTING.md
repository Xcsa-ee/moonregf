# 参与与提交约定

## 提交标题

标题格式：方括号里写改动所在的层，后面一句话说清动作与对象。

    [nk] 修正压缩名称的字节数判定
    [log] 条目前进改用自带长度字段
    [docs] 补 REGF 字段偏移表

层只有这些：

| 前缀 | 覆盖范围 |
| --- | --- |
| hdr | base block、校验和、序列号 |
| cell | cell 头与 hbin |
| nk | 键节点与其名称编码 |
| lf | 子键索引 lf / lh / li / ri |
| vk | 值记录、类型码、内联数据 |
| big | big data 分段（db） |
| log | 事务日志 HvLE 与重放 |
| reg | .reg 文本导入导出 |
| build | 写入器与布局 |
| cli | cmd/main 与参数 |
| ci | 工作流 |
| docs | README、DESIGN、本文件 |
| repo | 忽略规则、hooks、仓库设置 |

层前缀与文件对应：`hdr` 是 `regf_base_block.mbt`、`cell` 是 `regf_hbin.mbt`、`nk` 是 `regf_nk.mbt`、`lf` 是 `regf_subkey_index.mbt`、`vk` 是 `regf_vk.mbt`、`big` 在 `regf_vk.mbt` 与 `regf_builder.mbt`、`log` 是 `regf_hvle.mbt`、`reg` 是 `regt_*.mbt`、`build` 是 `regf_builder.mbt`。

一次提交只动一层，跨层改动拆开；标题不超过 50 个字；正文写清为什么改、怎么验证。

## 本地门禁

    moon fmt --check
    moon check --target wasm-gc --deny-warn
    moon build --target wasm-gc
    moon test --target wasm-gc
    moon test --target js
    moon run examples/basic

提交前 hook 只跑前两条，见 .githooks/pre-commit；推送前跑全量。

## 夹具与真实 hive

examples/sample.reg 是手工维护的 .reg 夹具，覆盖 dword、hex(2) 与裸 hex 三种写法，CI 用它做 .reg → hive → .reg 往返。

真实 hive 一律不进仓库：*.hive、*.LOG1、*.LOG2、*.reg 默认被忽略，只有 examples/*.reg 例外。
对拍时把它放在仓库外，直接用 CLI 读：

    moon run cmd/main -- <仓库外的 hive 路径> --values

## 改解析器之前

先看 DESIGN.md 的「REGF 字段偏移」一节：那是这些偏移的唯一口径。改解析器先改表，再改代码与测试；
偏移算错不会崩，只会把后面的记录整体读偏，所以每个偏移都要有一个白盒用例守着。
