#!/bin/bash
# QML 语法检查（本地与 CI 共用，版本无关）
#
# 背景：qmllint 的报错文案随版本变化（"Syntax error" / "Expected token ..."），
# 而且只有 Qt 6.5+ 才有 --bare；Ubuntu 24.04 的 qt6-declarative-dev-tools 是 6.4，
# 既没有 --bare、又会因为"import 解析不了"的噪音警告返回非零。
# 历史上这道门是空的：CI 里 qmllint 根本不在 PATH（command not found），
# 却因为 grep 不到 "Syntax error" 而打印 "QML 语法 OK"。
#
# 这里的做法：
#   1) 先用一个**故意写坏**的文件自检：这道门必须能判它失败——否则本脚本直接报错退出，
#      绝不留下"永远通过"的空门；
#   2) 有 --bare 时用退出码判定；没有时用"经自检验证过的报错文案集合"判定
#      （自检已经证明该版本会用这个集合报语法错）。
set -u
cd "$(dirname "$0")/.." || exit 1

QML="${QML:-qmllint}"
if [ -x "$QML" ]; then
    :
elif command -v "$QML" >/dev/null 2>&1; then
    :
else
    echo "找不到 qmllint（QML=$QML）——CI 里请装 qt6-declarative-dev-tools 并把 /usr/lib/qt6/bin 加进 PATH"
    exit 2
fi

FILES=(plasmoid/contents/ui/*.qml)
BARE=0
"$QML" --help 2>&1 | grep -q -- '--bare' && BARE=1

BAD=$(mktemp --suffix=.qml)
cp plasmoid/contents/ui/main.qml "$BAD"
printf '\nItem { property int x: }\n' >> "$BAD"
OUT=$(mktemp)
# 语法错误在不同版本下的不同措辞（自检会验证本版本确实用其中之一）
SYN='Syntax error|Expected token|Expected end of|Unexpected token|Unexpected end of'

if [ "$BARE" = 1 ]; then
    if "$QML" --bare "$BAD" >/dev/null 2>&1; then
        echo "FAIL 自检：故意写坏的 QML 竟然通过了（这道门是空的）"
        exit 1
    fi
    if ! "$QML" --bare "${FILES[@]}"; then
        echo "FAIL QML 有语法错误（见上）"
        exit 1
    fi
else
    "$QML" "$BAD" >"$OUT" 2>&1 || true
    if ! grep -E "$SYN" "$OUT" | grep -qv '^Warning:'; then
        echo "FAIL 自检：本机 qmllint（$("$QML" --version 2>&1 | head -1)）报语法错的措辞不在已知集合里，"
        echo "     无法可靠判定——请升级/固定工具版本，不要留一道空门"
        exit 1
    fi
    "$QML" "${FILES[@]}" >"$OUT" 2>&1 || true
    if grep -E "$SYN" "$OUT" | grep -qv '^Warning:'; then
        echo "FAIL QML 有语法错误："
        grep -E "$SYN" "$OUT" | grep -v '^Warning:' | head -5
        exit 1
    fi
    echo "（本机 qmllint 无 --bare：已用自检验证过的措辞集合判定，import 相关噪音忽略）"
fi
echo "QML 语法检查通过"
