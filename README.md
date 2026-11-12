# moonregf

一个 hive 是 4096 字节的 base block 加一串按 8 字节对齐的 cell：nk 指向子键索引与值列表，
vk 的数据可能拆进多个 db 段，sk 里还嵌着安全描述符。moonregf 逐字段读出这些记录、允许改完再写回，
全部用 MoonBit 完成，在 wasm-gc 与 js 后端都不碰 Windows API。

Windows 把 NTUSER.DAT、SYSTEM、SOFTWARE 等配置单元以 REGF 格式存盘。本项目让 Linux CI 与浏览器里的
MoonBit 代码也能读取、生成 hive，并把 `.reg` 文本导入成 hive；零 FFI 这一约束的理由与代价见
[DESIGN.md](DESIGN.md)。

## 安装

    moon add Xcsa-ee/moonregf

moon.pkg 中导入：

    import {
      "Xcsa-ee/moonregf",
    }

## 读取

    match @moonregf.parse_header(bytes) {
      Ok(header) => println(header.file_name)
      Err(error) => println(error.message())
    }

遍历键树、读取键值：

    for entry in @moonregf.walk_key_tree(bytes, header.root_cell_offset, 3) {
      println(entry.path)
    }
    match @moonregf.list_values(bytes, key) {
      Ok(values) => for value in values { println(value.name + " = " + value.data_type.label()) }
      Err(error) => println(error.message())
    }

想先看清楚这些字节长什么样，见 [docs/byte-walkthrough.md](docs/byte-walkthrough.md)：一个 8 KiB hive 的 base block、hbin 头与根 cell 的真实十六进制，逐字段对照偏移。

## 写入

    let builder = @moonregf.HiveBuilder::new()
    let software = builder.add_key(0, "Software")
    builder.set_string(software, "Install", "Hello")
    builder.set_dword(software, "Count", 42)
    match builder.build() {
      Ok(bytes) => println(bytes.length())
      Err(error) => println(error.message())
    }

## `.reg` 导入

    match @moonregf.parse_reg_bytes(raw) {
      Ok(file) => match file.to_builder() {
        Ok(builder) => builder.build()
        Err(error) => println(error.message())
      }
      Err(error) => println(error.message())
    }

命令行：

    moon run cmd/main -- <path-to-NTUSER.DAT>
    moon run cmd/main -- <path-to-NTUSER.DAT> --values
    moon run cmd/main -- <path-to-NTUSER.DAT> --security
    moon run cmd/main -- --build demo.hive
    moon run cmd/main -- --import-reg backup.reg rebuilt.hive
    moon run cmd/main -- --export-reg rebuilt.hive out.reg HKEY_CURRENT_USER
    moon run cmd/main -- --replay-log dirty.hive dirty.hive.LOG1 clean.hive
    moon run cmd/main -- --rebuild in.hive out.hive

## 读一个真实 hive 的可复现路径

登录会话里 `%USERPROFILE%\NTUSER.DAT` 正被系统独占，直接读会失败：

    I/O error: Failed to read file C:\Users\<你>\NTUSER.DAT: 另一个程序正在使用此文件，进程无法访问。 (os error 32)

先取一份可读的 hive，任选其一：`reg save HKCU\Software software.hive /y`（需备份权限，非管理员会报 `A required privilege is not held by the client`）；从离线镜像或卷影副本复制；或读他人导出的 `.reg`、用构造器生成的 hive。

不依赖任何外部文件的最小演示（第一条会在当前目录生成 `demo.hive`）：

    moon run cmd/main -- --build demo.hive
    moon run cmd/main -- demo.hive
    moon run cmd/main -- demo.hive --values

在 `C:\Users\Default\NTUSER.DAT`（262,144 B）上实测：`walk_key_tree(data, header.root_cell_offset, 64)` 全深度遍历得 634 个键，`list_values` 汇总 1,065 个值；同一份 hive 用 regipy 6.5.0 逐条比对，路径与值名的对称差为 0（2026-11-08，在全新工程 `moon add Xcsa-ee/moonregf@0.2.0` 内运行；CLI 默认只列 depth 3 的键）。


## 修改已有 hive

`HiveEditor` 把 hive 读进内存，改完再写回，并保留原有元数据：

    let editor = @moonregf.HiveEditor::open(raw)
    if let Some(key) = editor.find("ROOT/Software/Vendor") {
      editor.set_dword(key, "Count", 7)
      let _ = editor.delete_value(key, "Install")
      let added = editor.add_key(key, "Inner")
      editor.set_string(added, "Note", "added")
    }
    let bytes = editor.build()

保真的字段：nk 的写入时间戳、访问位与标志位，类名，sk 安全描述符，以及 base block 的文件名与序列号。

重建是一次全量重写：空闲空间与已删除记录不会保留下来，所以 `--rebuild` 默认用 `open_strict`，
一旦加载时丢掉过记录就拒绝写出；确需写出时加 `--force`，它会先打印丢掉了多少值与子键列表。
写入器按 4096 字节分箱：每个 bin 自带 32 字节 hbin 头，bin 尾部补空闲 cell，单个 cell 放不进当前 bin 时它会独占一个按需扩大的 bin。写出的多 bin hive 与 Windows 自己的布局同形。
在本机 `NTUSER.DAT` 上做过往返验证：634 键 / 1,065 值在重建后与原文件一致（regipy 双向计数相同），属主、属组与 ACL 标志不变。

## 示例

`examples/basic` 在内存里构造一个 hive，再读回并打印每个键与值，不需要任何输入文件：

    moon run examples/basic


## 从十六进制走到写回

想先看清字节，读 [docs/byte-walkthrough.md](docs/byte-walkthrough.md)：它把一个 8 KiB hive 从
`0x0000 72 65 67 66` 起逐字段拆开，手算前 508 字节的 XOR 校验和，并给出自己复核用的
`moon run cmd/main -- --build demo.hive` 与 `xxd` 命令。
[docs/demo.mp4](docs/demo.mp4) 是同一条链的动态版本，依次是：base block 与校验和、键树遍历、
值导出与 regipy 对拍、构造 hive 后由独立解析器读回、`.reg` 往返、HvLE 脏页重放。

## 格式依据与对拍边界

REGF 的记录布局与 `.reg` 文本按公开格式说明实现，未移植任何上游源码；字段偏移的唯一口径是
[DESIGN.md](DESIGN.md) 里的表。对拍只在仓库外用两个独立解析器做：Windows 自带 `reg.exe` 与
regipy 6.5.0（Apache-2.0），在本机比对键路径与值名，二者都不进仓库、不参与运行。

## 记录支持矩阵

按 REGF 的结构逐项列出读写状态。写不了的地方返回明确错误，不静默截断或丢弃。

| 结构 | 读取 | 写入 | 说明 |
| --- | --- | --- | --- |
| base block | 是 | 是 | 校验和按前 508 字节逐 u32 异或重算 |
| hbin / cell | 是 | 是 | cell 长度含 4 字节头，按 8 字节对齐 |
| nk 键节点 | 是 | 是 | 读取支持压缩与 UTF-16 名称；写入按名称自动选压缩或 UTF-16LE |
| lf / lh / li | 是 | 是 | 按子键数与名称编码自动选择，也可显式指定 |
| ri 根索引 | 是 | 是 | 子键超过 500 个时自动生成，每片 500 项 |
| vk 值记录 | 是 | 是 | 0–11 共 12 种类型码都可原样读写；语义访问器只覆盖 SZ / DWORD / MULTI_SZ |
| 内联数据 | 是 | 是 | 数据不超过 4 字节时直接存在 vk 里 |
| big data（db） | 是 | 是 | 读取按段拼接；写入按 16344 字节分段 |
| del（已删除键） | 是 | 不适用 | `--orphans` 扫出未被活动键树引用的 nk 与 del 记录 |
| sk 安全描述符 | 是 | 是 | 读取可解出属主、属组与 DACL / ACE；写入把给定描述符字节原样嵌入 sk，不构造 ACE |
| .reg 文本 | 是 | 是 | 导入支持 REGEDIT4 与 version 5.00；导出固定 version 5.00 |
| .reg 删除段 | 否 | 否 | 遇到 [-key] 返回 UnsupportedDelete |
| HvLE 事务日志 | 是 | 否 | 只重放 8.1 及更新版本的单份 HvLE 日志；不生成日志，不自动挑选 .LOG1 / .LOG2 |

## 持续集成

`.github/workflows/regf.yml` 按 hive 的三层结构分开跑，一个作业对应一种会出错的方式：

1. **字节布局**：`moon fmt --check` + `moon check --target wasm-gc --deny-warn`，再 `moon build`；
   守的是 DESIGN.md 里那张偏移表有没有被改动带偏。
2. **记录解析**：`wasm-gc` 与 `js` 两个后端的矩阵，各自跑 `moon test --deny-warn`；
   同一份 cell 在两个后端必须解出同样的 nk / vk。
3. **写读往返**：先用 `--build` 生成 hive，再用本库自己的 CLI 读回，断言键数 3、值数 3、校验和存在；
   再把 `examples/sample.reg` 导入成 hive 并导出回文本，断言 `dword:0000002a`、`hex(2)` 与嵌套键都在。

## 格式版本与互操作

读取端接受 base block 声明的 1.3 / 1.5 / 1.6 三个版本（`HiveHeader::version_supported`），其余版本仍可解析但会报告为不受支持。
本机 `NTUSER.DAT` 是 1.5；把同一份夹具的版本字段改成 1.3 与 1.6 后，本库与 regipy 都能读出相同的键树，
但**写出一律固定为 1.5**（`regf_builder.mbt` 的 base block 常量），`--rebuild` 不会保留原版本号。

事务日志按序列号次序应用：先较旧的一份，再较新的一份；比 hive 次序列号旧的日志不动作。
现有的 `replay_log(hive, log)` 一次只吃一份日志，两份日志的顺序合并目前由调用方串联（测试里手工调用两次），
CLI 也只接一个日志参数。在真实 `NTUSER.DAT.LOG1` 上验证过两种情形：干净 hive 应用 0 条且字节不变，
降次序列号后应用 1 条并与独立实现逐字节一致。

## 边界

下面是明确的工程边界，不是待办：

- 不调用 Windows 注册表 API，不把 hive 挂载或加载回 Windows；REG_LINK 只当作 UTF-16LE 文本读出，不解析目标、不跟随。
- `.reg` 导入不支持 [-key] 删除段（UnsupportedDelete）；导出固定 UTF-8，导入接受 UTF-16LE 与 UTF-8。
- 事务日志只解析 Windows 8.1 及更新版本的 HvLE；更早的 512 字节头格式返回 UnsupportedLogVersion；不生成日志。
- `HiveEditor` / `--rebuild` 是全量重写：不保留空闲空间、已删除记录与未引用 cell，不复用空闲 cell，不做增量分配。
- nk 的写入时间戳按两个 u32 原样保真，不解释成日历时间；`--orphans` 只扫未引用的 nk 与 del 记录。

## 数据与隐私

hive 通常含用户名、路径、产品密钥等信息，属于个人数据。因此：

- 库本身不发网络请求，不写日志文件，不读取文件路径之外的上下文。
- CLI 只把解析结果打印到标准输出，不缓存、不上传。
- 仓库的忽略规则默认挡住 *.hive、*.LOG1、*.LOG2、*.reg，只有 examples/*.reg 例外；对拍用的真实 hive 一律留在仓库外。

## 开发与提交约定

提交标题按改动所在的 REGF 记录层加方括号前缀，实际在用的层与对应文件见
[CONTRIBUTING.md](CONTRIBUTING.md)（该文也写明了 2026-11-08 从 conventional commits 切换过来的原因）。
夹具、真实 hive 的存放规则与本地门禁命令同样写在那里。

## 许可

Apache-2.0，见 LICENSE。
