# 参与与提交约定

## 提交标题

标题格式：方括号里写改动所在的 REGF 记录层，后面一句话说清动作与对象。

    [cell] 畸形 hive 不再 panic，取值按类型判定
    [sk] 解析 DACL 里的访问控制项
    [bin] 写入器按 4096 字节分箱

现在实际在用的层（与 `git log --oneline` 一致）：

| 前缀 | 覆盖范围 | 主要文件 |
| --- | --- | --- |
| hdr | base block、校验和、序列号、版本 | `regf_base_block.mbt` |
| cell | cell 头、hbin、越界判定 | `regf_hbin.mbt` |
| bin | 字节工具与写入器的 bin 分箱布局 | `bin_*.mbt`、`regf_builder.mbt` |
| sk | 安全描述符、DACL / ACE | `regf_sk.mbt`、`regf_acl.mbt` |
| rec | 未引用记录与恢复扫描 | `regf_recovery.mbt` |
| edit | HiveEditor 的打开、修改与回写 | `regf_editor.mbt` |
| build | 写入器与整体布局 | `regf_builder.mbt` |
| docs | README、DESIGN、本文件、docs/ | — |
| repo | 忽略规则、hooks、版本与仓库设置 | — |

尚未用到的层（`nk` / `lf` / `vk` / `big` / `log` / `reg` / `cli` / `ci`）按同一规则补进来即可，
不在表里预留没有提交对应的前缀。

一次提交只动一层，跨层改动拆开；标题不超过 50 个字；正文写清为什么改、怎么验证。

历史：2026-11-08 之前（`1c22504` 及更早）用 conventional commits（`feat:` / `chore:` / `docs:` / `ci:` 等），
从 `[docs] 固定按层提交前缀` 起改成按 REGF 记录分层，因为提交粒度与 `regf_*.mbt` 的文件划分一一对应。
历史提交不重写，`git log` 里那段切换是有记录的做法变更。

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
