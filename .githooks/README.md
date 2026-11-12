# 为什么提交前只查格式与类型

REGF 的 cell 长度按 8 字节对齐，长度字段的符号位表示 cell 是否已分配。偏移一旦算错，
解析器通常不会崩，只会把后面的 nk / vk 整体读偏，往往要到 `.reg` 导出时才看得出结果不对。
所以 `pre-commit` 跑 `moon fmt --check` 与 `moon check --target wasm-gc --deny-warn`，
把改动挡在 DESIGN.md 那张偏移表的口径内；行为是否仍正确交给 `moon test` 与 CI 的三个作业。

启用（一次性，仅本地生效）：`git config core.hooksPath .githooks`。
