# 提交前门禁

启用一次即可：

    git config core.hooksPath .githooks

`pre-commit` 只跑 `moon fmt --check` 与 `moon check --target wasm-gc --deny-warn`。
REGF 的 cell 大小按 8 字节对齐，任何一处算错都会让后续偏移整体移位而不是直接报错；
这两道检查能在几秒内拦住大部分这类改动，测试留到 `moon test` 与 CI。
