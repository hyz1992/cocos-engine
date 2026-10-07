#!/usr/bin/env bash
# 重新下载 native/external（git-ignored 的下载物）之后，应用本目录记录的本地补丁。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTERNAL="$(cd "$HERE/../../external" && pwd)"
PATCH="$HERE/external.patch"

if [ ! -d "$EXTERNAL/.git" ]; then
    echo "错误：$EXTERNAL 不是 git 仓库，请先按 native/external-config.json 的 checkout 值克隆 external。" >&2
    exit 1
fi
if git -C "$EXTERNAL" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "补丁已应用，跳过。"
    exit 0
fi
git -C "$EXTERNAL" apply "$PATCH"
echo "已应用 $(basename "$PATCH") 到 $EXTERNAL"
