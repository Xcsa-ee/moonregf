# moonregf

纯 MoonBit 实现的 Windows 注册表 hive 文件（REGF 二进制格式）读取与写入库：不依赖 Windows API、C 库或 FFI。

Windows 把 NTUSER.DAT、SYSTEM、SOFTWARE 等配置单元以 REGF 格式存盘。本项目在纯 MoonBit 中解析该格式，
让工具链在 Windows 之外（Linux CI、wasm-gc、浏览器）也能读取 hive 内容。

## 安装

    moon add Xcsa-ee/moonregf

moon.pkg 中导入：

    import {
      "Xcsa-ee/moonregf",
    }

## 用法

    match @moonregf.parse_header(bytes) {
      Ok(header) => println(header.file_name)
      Err(error) => println(error.message())
    }

命令行查看文件头：

    moon run cmd/main -- <path-to-NTUSER.DAT>

## 当前进度

- [x] base block（4096 字节）解析：签名、主/次序列号、版本、文件类型、根 cell 偏移、hive bins 大小、UTF-16LE 文件名、XOR 校验和
- [ ] cell 分配器与 nk/vk/sk 结构
- [ ] 子键索引（lf/lh/li/ri）与键树遍历
- [ ] value 数据读取（含 big data 分段）
- [ ] 事务日志 .LOG1/.LOG2 重放
- [ ] 写入器与 .reg 互换

## 许可

Apache-2.0，见 LICENSE。
