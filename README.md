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
    moon run cmd/main -- --build demo.hive
    moon run cmd/main -- --import-reg backup.reg rebuilt.hive
    moon run cmd/main -- --export-reg rebuilt.hive out.reg HKEY_CURRENT_USER
    moon run cmd/main -- --replay-log dirty.hive dirty.hive.LOG1 clean.hive

## 示例

`examples/basic` 在内存里构造一个 hive，再读回并打印每个键与值，不需要任何输入文件：

    moon run examples/basic


## 演示视频

[docs/demo.mp4](docs/demo.mp4) 用真实命令演示：两个后端的门禁与测试、解析本机 hive、遍历键树、值导出并与独立解析器对拍、生成 hive 后由独立解析器读回、`.reg` 往返、事务日志重放。

## 参考与来源

实现依据、关键判断与对拍方式见 [DESIGN.md](DESIGN.md)。格式按公开说明实现，未移植上游源码；`reg.exe` 与 regipy 只在本机作为独立解析器对拍，不进入仓库、不作为运行依赖。

## 当前进度

- [x] base block（4096 字节）解析：签名、主/次序列号、版本、文件类型、根 cell 偏移、hive bins 大小、UTF-16LE 文件名、XOR 校验和
- [x] cell 头解析与键节点（nk）解析
- [x] 子键索引 lf / lh / li / ri（ri 递归展开）与键树遍历
- [x] 值记录（vk）解析：类型码映射、inline 数据、值列表、big data 分段拼接、REG_SZ 与 REG_MULTI_SZ 解码
- [x] 写入器：从键树生成 base block、hbin、nk/vk/lf 记录、值列表与数据 cell，自动计算校验和
- [x] `.reg` 文本导入：REGEDIT4 / version 5.00、续行、dword、hex、hex(N) 形式
- [x] `.reg` 文本导出：`version 5.00` 头、dword / hex / hex(N) 渲染、名称转义、按根路径前缀生成节

## 持续集成

`.github/workflows/ci.yml` 在 Ubuntu 上安装 MoonBit 工具链并依次执行格式检查、检查、构建、
wasm-gc 与 js 两个后端的测试，以及 `examples/basic`。

- [x] 事务日志 `.LOG1/.LOG2` 重放：解析 Windows 8.1+ 的 HvLE 条目（条目大小、序列号、脏页数、页引用），按存储顺序应用脏页并更新 base block 序列号与校验和，陈旧日志不动作

## 已知限制

- 写入器只接受 ASCII 键名与值名，非 ASCII 名称返回 UnsupportedName。
- 单个值最大 16344 字节，超过者返回 ValueTooLarge（尚未写 big data 分段）。
- `.reg` 导入不支持 [-key] 删除段，遇到时返回 UnsupportedDelete。
- 事务日志只解析 Windows 8.1 及更新版本的 HvLE 格式；更早的 512 字节头格式返回 UnsupportedLogVersion。
- `.reg` 导出输出 UTF-8 文本；导入端支持 UTF-16LE 与 UTF-8 两种输入。

## 许可

Apache-2.0，见 LICENSE。
