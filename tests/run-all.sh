#!/bin/bash
# 一键跑全部检查（本地和 CI 用同一套）：
#   1) bash -n 语法检查
#   2) shellcheck 静态检查（有就用，没有就跳过）
#   3) 配置库单测 tests/test-config.sh
#   4) 控制脚本 mock 端到端测试 tests/test-ctl.sh
#   5) backend/ 与插件包内副本一致性
# 用法：bash tests/run-all.sh
set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0

step(){ printf '\n===== %s =====\n' "$1"; }
bad(){ printf '  FAIL %s\n' "$1"; FAIL=1; }

step "1) 语法检查（bash -n）"
for f in install.sh sync-backend.sh build-translations.sh \
         backend/kde-hotspot-config.sh backend/kde-hotspot-ctl backend/kde-hotspot.sh backend/deploy.sh \
         tests/test-config.sh tests/test-ctl.sh tests/test-supervisor.sh tests/run-all.sh; do
    if bash -n "$f" 2>/dev/null; then
        printf '  ok   %s\n' "$f"
    else
        bad "$f 语法错误"
        bash -n "$f"
    fi
done

step "2) shellcheck 静态检查"
SC=""
if [ -x .tools/shellcheck ]; then
    SC=.tools/shellcheck
elif command -v shellcheck >/dev/null 2>&1; then
    SC=shellcheck
fi
if [ -n "$SC" ]; then
    if "$SC" backend/kde-hotspot-config.sh backend/kde-hotspot-ctl backend/kde-hotspot.sh \
               backend/deploy.sh tests/test-config.sh tests/test-ctl.sh tests/test-supervisor.sh tests/run-all.sh \
               install.sh sync-backend.sh build-translations.sh; then
        echo "  ok   无告警"
    else
        bad "shellcheck 有告警（见上）"
    fi
else
    echo "  skip 未安装 shellcheck（.tools/shellcheck 或 PATH 里都没有）"
fi

step "3) 配置库测试"
bash tests/test-config.sh || bad "配置库测试失败"

step "4) 控制脚本测试（mock 端到端）"
bash tests/test-ctl.sh || bad "控制脚本测试失败"

step "4b) 监督脚本测试（mock 端到端）"
bash tests/test-supervisor.sh || bad "监督脚本测试失败"

step "5) backend 与插件包内副本一致性"
bash sync-backend.sh --check || bad "两处后端不一致（运行 bash sync-backend.sh）"

step "6) QML 语法检查（qmllint，若可用）"
QML=""
QML_LD=""
if [ -x .tools/qml/qmllint ]; then
    QML="$PWD/.tools/qml/qmllint"
    QML_LD="$PWD/.tools/qml/lib"       # qmllint 需要 libQt6QmlCompiler
elif command -v qmllint >/dev/null 2>&1; then
    QML=qmllint
fi
if [ -n "$QML" ]; then
    # 只看语法：CI 里没有 Plasma 的 QML 模块，import 解析不了会产生大量
    # “Property does not exist / Unqualified access” 之类的噪音警告，不算失败。
    QMLOUT=$(LD_LIBRARY_PATH="$QML_LD" "$QML" plasmoid/contents/ui/*.qml 2>&1 || true)
    if printf '%s\n' "$QMLOUT" | grep -qi 'Syntax error'; then
        bad "QML 语法错误"
        printf '%s\n' "$QMLOUT" | grep -i 'Syntax error'
    else
        echo "  ok   无语法错误（未解析 import 的警告不计）"
    fi
else
    echo "  skip 未安装 qmllint"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    echo "全部检查通过"
else
    echo "有检查未通过"
fi
exit "$FAIL"
