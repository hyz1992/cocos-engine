# native/external 本地补丁

`native/external/` 是外部下载物（tag 见 `native/external-config.json` 的 `checkout` 字段，
当前为 `v3.8.7-18`），**不在版本控制中**。本目录记录必须长期保留的本地补丁，
重新下载 external（换 tag / 换机器 / 新同事拉代码）后需要重新应用。

| 文件 | 改动 | 原因 |
|---|---|---|
| `sources/enoki/half.h` | 不再特化 `std::is_floating_point` / `is_arithmetic` / `is_signed`，改为特化 libc++ 内部钩子 `__libcpp_is_floating_point` | 新版 libc++ 给这些 trait 加了 `_LIBCPP_NO_SPECIALIZATIONS`，特化会直接报错：`Users are not allowed to specialize this standard library entity` |
| `sources/xxtea/xxtea.cpp` | `xxtea_decrypt` 增加 `data_len < 8` 守卫；`xxtea_to_byte_array` 增加 `malloc` 判空 | 空 / 被截断的 `.jsc`（下载不完整）会让 `xxtea_long_decrypt` 的 `n = len - 1` 下溢成 `0xFFFFFFFF` 并越界访问；`malloc` 失败时原代码会向空指针写入。两个调用方（`native/cocos/bindings/manual/jsb_global_init.cpp`）本来就会处理 `NULL` 并报 `Can't decrypt code` |

## 应用方式

```bash
bash native/tools/external-patches/apply.sh
```

脚本进入 `native/external` 并 `git apply` 本目录的 `external.patch`；
若检测到已应用则直接跳过。

## 维护

补丁内容由 `git -C native/external diff > native/tools/external-patches/external.patch` 生成，
即 external 仓库相对其 checkout tag 的全部本地改动。新增外部补丁时重新生成该文件即可。
