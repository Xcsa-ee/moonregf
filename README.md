# moonregf

纯 MoonBit 实现的 Windows 注册表 hive 文件（REGF 二进制格式）读取与写入库：不依赖 Windows API、C 库或 FFI。

Windows 把 NTUSER.DAT、SYSTEM、SOFTWARE 等配置单元以 REGF 格式存盘。本项目在纯 MoonBit 中读写该格式，
让工具链在 Windows 之外（Linux CI、wasm-gc、浏览器）也能读取与生成 hive，并把 `.reg` 文本导入成 hive。

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

写入器按 4096 字节分箱：每个 bin 自带 32 字节 hbin 头，bin 尾部补空闲 cell，单个 cell 放不进当前 bin 时它会独占一个按需扩大的 bin。写出的多 bin hive 与 Windows 自己的布局同形。
在本机 `NTUSER.DAT` 上做过往返验证：634 键 / 1,065 值在重建后与原文件一致（regipy 双向计数相同），属主、属组与 ACL 标志不变。

## 示例

`examples/basic` 在内存里构造一个 hive，再读回并打印每个键与值，不需要任何输入文件：

    moon run examples/basic


## 演示视频

[docs/demo.mp4](docs/demo.mp4) 用真实命令演示：两个后端的门禁与测试、解析本机 hive、遍历键树、值导出并与独立解析器对拍、生成 hive 后由独立解析器读回、`.reg` 往返、事务日志重放。

## 参考与来源

实现依据、关键判断与对拍方式见 [DESIGN.md](DESIGN.md)。格式按公开说明实现，未移植上游源码；`reg.exe` 与 regipy 只在本机作为独立解析器对拍，不进入仓库、不作为运行依赖。

## 记录支持矩阵

按 REGF 的结构逐项列出读写状态。写不了的地方返回明确错误，不静默截断或丢弃。

| 结构 | 读取 | 写入 | 说明 |
| --- | --- | --- | --- |
| base block | 是 | 是 | 校验和按前 508 字节逐 u32 异或重算 |
| hbin / cell | 是 | 是 | cell 长度含 4 字节头，按 8 字节对齐 |
| nk 键节点 | 是 | 是 | 读取支持压缩与 UTF-16 名称；写入按名称自动选压缩或 UTF-16LE |
| lf / lh / li | 是 | 是 | 按子键数与名称编码自动选择，也可显式指定 |
| ri 根索引 | 是 | 是 | 子键超过 500 个时自动生成，每片 500 项 |
| vk 值记录 | 是 | 是 | 类型码 1 / 2 / 3 / 4 / 7 / 11 已映射 |
| 内联数据 | 是 | 是 | 数据不超过 4 字节时直接存在 vk 里 |
| big data（db） | 是 | 是 | 读取按段拼接；写入按 16344 字节分段 |
| del（已删除键） | 是 | 不适用 | `--orphans` 扫出未被活动键树引用的 nk 与 del 记录 |
| sk 安全描述符 | 是 | 是 | 解析属主与属组 SID、ACL 是否存在；写入按给定描述符生成 sk 记录 |
| .reg 文本 | 是 | 是 | 导入支持 REGEDIT4 与 version 5.00；导出固定 version 5.00 |
| .reg 删除段 | 否 | 否 | 遇到 [-key] 返回 UnsupportedDelete |
| HvLE 事务日志 | 是 | 否 | 只解析 8.1 及更新版本；写入与生成日志不在范围内 |

## 持续集成

`.github/workflows/regf.yml` 拆成三个作业，红了能一眼看出是哪一层出问题：

1. **字节布局**：`moon fmt --check` + `moon check --target wasm-gc --deny-warn`，再 `moon build`。
2. **解析器测试**：`wasm-gc` 与 `js` 两个后端的矩阵，各自跑 `moon test --deny-warn`。
3. **写出的 hive 必须能被读回**：先用 `--build` 生成 hive，再用本库自己的 CLI 读回，断言键数 3、值数 3、校验和存在；
   再把 `examples/sample.reg` 导入成 hive 并导出回文本，断言 `dword:0000002a`、`hex(2)` 与嵌套键都在。

## 格式版本与互操作

读取端接受 base block 声明的 1.3 / 1.5 / 1.6 三个版本（`HiveHeader::version_supported`），其余版本仍可解析但会报告为不受支持。
本机 `NTUSER.DAT` 是 1.5；把同一份夹具的版本字段改成 1.3 与 1.6 后，本库与 regipy 都能读出相同的键树，也能经 `--rebuild` 写回。

事务日志按序列号次序合并：先应用较旧的一份，再应用较新的一份；比 hive 次序列号旧的日志不动作。
在真实 `NTUSER.DAT.LOG1` 上验证过两种情形：干净 hive 应用 0 条且字节不变，降次序列号后应用 1 条并与独立实现逐字节一致。

## 已知限制

- `.reg` 导入不支持 [-key] 删除段，遇到时返回 UnsupportedDelete。
- 事务日志只解析 Windows 8.1 及更新版本的 HvLE 格式；更早的 512 字节头格式返回 UnsupportedLogVersion。
- `.reg` 导出输出 UTF-8 文本；导入端支持 UTF-16LE 与 UTF-8 两种输入。

## 数据与隐私

hive 通常含用户名、路径、产品密钥等信息，属于个人数据。因此：

- 库本身不发网络请求，不写日志文件，不读取文件路径之外的上下文。
- CLI 只把解析结果打印到标准输出，不缓存、不上传。
- 仓库的忽略规则默认挡住 *.hive、*.LOG1、*.LOG2、*.reg，只有 examples/*.reg 例外；对拍用的真实 hive 一律留在仓库外。

## 开发与提交约定

提交标题按改动所在的层加方括号前缀（hdr / cell / nk / lf / vk / big / log / reg / build / cli / ci / docs / repo），
夹具再生步骤与本地门禁命令写在 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

Apache-2.0，见 LICENSE。
