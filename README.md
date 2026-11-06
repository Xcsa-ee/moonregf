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

## 当前进度

- [x] base block（4096 字节）解析：签名、主/次序列号、版本、文件类型、根 cell 偏移、hive bins 大小、UTF-16LE 文件名、XOR 校验和
- [x] cell 头解析与键节点（nk）解析
- [x] 子键索引 lf / lh / li / ri（ri 递归展开）与键树遍历
- [x] 值记录（vk）解析：类型码映射、inline 数据、值列表、big data 分段拼接、REG_SZ 与 REG_MULTI_SZ 解码
- [x] 写入器：从键树生成 base block、hbin、nk/vk/lf 记录、值列表与数据 cell，自动计算校验和
- [x] `.reg` 文本导入：REGEDIT4 / version 5.00、续行、dword、hex、hex(N) 形式
- [ ] `.reg` 文本导出
- [ ] 事务日志 .LOG1/.LOG2 重放

## 已知限制

- 写入器只接受 ASCII 键名与值名，非 ASCII 名称返回 UnsupportedName。
- 单个值最大 16344 字节，超过者返回 ValueTooLarge（尚未写 big data 分段）。
- `.reg` 导入不支持 [-key] 删除段，遇到时返回 UnsupportedDelete。

## 许可

Apache-2.0，见 LICENSE。
