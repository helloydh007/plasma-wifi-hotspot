#!/bin/bash
# QML 语法检查（本地与 CI 共用，版本无关）
#
# 背景（都是真机上踩过的）：
#   * qmllint 的报错文案随版本变化（"Syntax error" / "Expected token …"），grep 固定文案 = 换版本就成空门；
#   * 只有 Qt 6.5+ 才有 --bare；Ubuntu 24.04 是 6.4，而且即使带 --bare，也会因 import/类型未解析返回非零；
#   * CI 里 qmllint 曾经压根不在 PATH（command not found），旧 workflow 却打印 "QML 语法 OK"。
#
# 做法：只看**错误行**，不看退出码、也不看固定文案：
#   1) 故意写坏一个文件自检：本版本 qmllint 必须能把它匹配到下面的措辞集合，
#      匹配不到就直接失败（说明这道门在该版本不可靠）——绝不留"永远通过"的空门；
#   2) 再查真实文件：只统计**非 Warning 行**里的语法错误措辞（import/类型噪音都带 "Warning:" 前缀）。
set -u
cd "$(dirname "$0")/.." || exit 1

QML="${QML:-qmllint}"
if [ -x "$QML" ]; then
    :
elif command -v "$QML" >/dev/null 2>&1; then
    :
else
    echo "找不到 qmllint（QML=$QML）——请装 qt6-declarative-dev-tools 并把 /usr/lib/qt6/bin 加进 PATH"
    exit 2
fi

FILES=(plasmoid/contents/ui/*.qml)
SYN='Syntax error|Expected token|Expected end of|Unexpected token|Unexpected end of|Unexpected EOF'
errs(){ grep -E "$SYN" "$1" 2>/dev/null | grep -v '^Warning:'; }

BAD=$(mktemp --suffix=.qml)
cp plasmoid/contents/ui/main.qml "$BAD"
printf '\nItem { property int x: }\n' >> "$BAD"
OUT=$(mktemp)

BARE=""
"$QML" --help 2>&1 | grep -q -- '--bare' && BARE="--bare"

"$QML" $BARE "$BAD" >"$OUT" 2>&1 || true
if [ -z "$(errs "$OUT")" ]; then
    echo "FAIL 自检：故意写坏的 QML 没被认成语法错误（这道门在本版本 qmllint 上不可靠）"
    echo "     版本：$("$QML" --version 2>&1 | head -1)"
    head -5 "$OUT" | sed 's/^/       /'
    exit 1
fi

"$QML" $BARE "${FILES[@]}" >"$OUT" 2>&1 || true
if [ -n "$(errs "$OUT")" ]; then
    echo "FAIL QML 有语法错误："
    errs "$OUT" | head -5
    exit 1
fi
echo "QML 语法检查通过（自检通过；import/类型噪音忽略${BARE:+；使用了 --bare}）"
