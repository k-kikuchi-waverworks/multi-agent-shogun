#!/usr/bin/env bash
# install_gate_hooks.sh — pre-commit shim を .git/hooks へ据える (cmd_1352)
#
# shim は 3 行 = 正本 (scripts/gate_precommit.sh) を呼ぶだけ。
# 既存の pre-commit が居れば pre-commit.local へ退避し、shim が先に既存分を呼ぶ (潰さぬ)。
# 冪等 (何度走らせても同じ結果)。
set -u

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HOOK="$REPO/.git/hooks/pre-commit"
MARKER="cmd_1352 silent-pitfall gate shim"

if [ ! -d "$REPO/.git/hooks" ]; then
    echo "install_gate_hooks: .git/hooks が無い ($REPO は git repo か?)" >&2
    exit 2
fi

if [ -f "$HOOK" ] && ! grep -q "$MARKER" "$HOOK"; then
    echo "既存の pre-commit を退避: pre-commit.local (shim が先に呼ぶ)"
    mv "$HOOK" "$HOOK.local"
fi

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# $MARKER — 正本は scripts/gate_precommit.sh (ここを太らせるな)
REPO="\$(git rev-parse --show-toplevel)"
if [ -x "\$REPO/.git/hooks/pre-commit.local" ]; then
    "\$REPO/.git/hooks/pre-commit.local" "\$@" || exit \$?
fi
exec bash "\$REPO/scripts/gate_precommit.sh"
EOF
chmod +x "$HOOK"
echo "据えた: $HOOK → scripts/gate_precommit.sh"
