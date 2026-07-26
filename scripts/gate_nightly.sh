#!/usr/bin/env bash
# gate_nightly.sh — 両 gate のフル再走 backstop (cmd_1352)
#
# cron (毎朝 06:30) から回る。pre-commit hook の取り零しを埋める:
#   ・hook は .git/hooks 住まいゆえ環境再構築で消えうる (cmd_1342 で六号が指摘した弱点)
#   ・gate-2 のフル再走 (変異全件) は commit 毎には重いゆえ日次でここが受け持つ
#   ・commit が無い日でも drift (後から足された ignore 規則・仕様変更による変異の無効化) を検分する
# 非 PASS は家老 inbox へ警告 (是正手順つき)。人が思い出して回す形にはせぬ。
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STAMP="$(date '+%Y-%m-%dT%H:%M:%S')"

# bats は nvm 配下ゆえ cron の素の PATH からは見えぬ。台帳の bats 系 entry (MUT-1339-*)
# が「bats: command not found = baseline 赤」で毎朝偽 UNDETERMINED 警告を出さぬよう、
# 見つからぬ時のみ最新 nvm bin を足す (常に赤い検知は無視されて死ぬ)。
if ! command -v bats >/dev/null 2>&1; then
    nvm_bin="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
    [ -n "$nvm_bin" ] && PATH="$PATH:$nvm_bin" && export PATH
fi

echo "── [gate_nightly] $STAMP 開始 ──"
# --committed = HEAD blob を正とする (fresh clone が受け取る中身の検分。作業ツリーを信ぜぬ
#  = 軍師二号が cmd_1349 QC で示した流儀。index 視点は pre-commit hook 側が受け持つ)
out1="$(bash "$SCRIPT_DIR/scripts/gate_artifact_capture.sh" --all --committed 2>&1)"; rc1=$?
out2="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" 2>&1)"; rc2=$?
# gate-2 付帯 (cmd_1352b): 台帳登録検知 — 変異testらしき file が台帳に無ければ名指しで警告
out3="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage 2>&1)"; rc3=$?

# ── backend 台帳延長 (cmd_1355): 順序検査 (9396d95) / gate X (cb873e9) の「検査の検査」──
# backend 側の検査群は台帳の外に在った = G2 型無効化 (検査を黙って殺す) に無防備だった
# (軍師一号の名指し・沈黙③⑨)。台帳は backend repo 側 (config/mutation_registry.yaml)、
# runner はここから --repo-root で跨いで撃つ。
# ★backend が見えぬ時は UNDETERMINED★ — submodule 未init / path 違い / disk 喪失の空振りを
# 黙って PASS にせぬ (検分できておらぬは緑ではない)。
BACKEND_ROOT="${GATE_BACKEND_ROOT:-$HOME/aituber-project/backend}"
BACKEND_ROOT="$(readlink -f "$BACKEND_ROOT" 2>/dev/null || echo "$BACKEND_ROOT")"  # 相対/リンクを正規化 (何を見たかを曖昧にせぬ)
BACKEND_REG="$BACKEND_ROOT/config/mutation_registry.yaml"
echo "[gate_nightly] backend 台帳 = $BACKEND_REG"
export AITUBER_BACKEND_ROOT="$BACKEND_ROOT"
export AITUBER_BACKEND_VENV_PY="${AITUBER_BACKEND_VENV_PY:-$BACKEND_ROOT/.venv/bin/python}"
if [ -f "$BACKEND_REG" ]; then
    out4="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --registry "$BACKEND_REG" --repo-root "$BACKEND_ROOT" 2>&1)"; rc4=$?
    out5="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage --registry "$BACKEND_REG" --repo-root "$BACKEND_ROOT" 2>&1)"; rc5=$?
else
    rc4=2; out4="[gate-2 backend] UNDETERMINED: backend 台帳が見えぬ ($BACKEND_REG) = submodule 未init / path 違いの疑い。検分できておらぬは緑ではない"
    rc5=2; out5="[gate-2 backend coverage] UNDETERMINED: backend 台帳が見えぬ ($BACKEND_REG) = 同上"
fi
printf '%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5"

# hook 消失検知: pre-commit shim は .git/hooks 住まいゆえ環境再構築で黙って消える
# (cmd_1342 で六号が指摘した弱点)。消えておれば commit 時の関所が不在 = 緑ではない。
hook_rc=0
if ! grep -q "cmd_1352 silent-pitfall gate shim" "$SCRIPT_DIR/.git/hooks/pre-commit" 2>/dev/null; then
    hook_rc=2
    echo "[gate_nightly] ⚠ pre-commit shim が居らぬ (環境再構築で消えた可能性)。bash scripts/install_gate_hooks.sh で再据付せよ"
fi

# ★配線消失検知 (cmd_1359)★: stall_watchdog は 2026-04-22 の設置以来3ヶ月、
# ★目は開いておったが【呼ぶ者が居らぬ】★まま発報0件であった (軍師二号の検分)。
# ★番人は書いただけでは番をせぬ★ — 配線が消えれば、誰にも気付かれず元の沈黙へ戻る。
# しかも「鳴らなかった」ことには誰も気付けぬ (alert の不在は無音と区別がつかぬ)。
# ゆえに ★毎朝 crontab を実際に読んで、呼ぶ者が居ることを確かめる★。
wiring_rc=0
if ! command -v crontab >/dev/null 2>&1; then
    wiring_rc=2
    echo "[gate_nightly] ⚠ crontab が見えぬゆえ stall_watchdog の配線を検分できぬ (UNDETERMINED=緑ではない)"
elif ! crontab -l 2>/dev/null | grep -q "stall_watchdog_cmd1359"; then
    wiring_rc=2
    echo "[gate_nightly] ⚠ stall_watchdog の cron 配線が消えておる = 帳簿漏れの番人が誰にも呼ばれておらぬ (cmd_1359 の再発)"
fi

verdict() { case "$1" in 0) echo PASS;; 1) echo FAIL;; *) echo UNDETERMINED;; esac; }

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ]; then
    # 警告は1行に畳む (inbox message の YAML 安全のため改行・コロン+空白を避ける)
    # 行連結は awk で行う (tr '\n' '・' は byte 置換ゆえ多byte文字の先頭1byteのみを埋め
    # 不正 UTF-8 を inbox へ混入させる — 2026-07-26 実測で発見した既存バグの是正)
    # PASS 行は除外する: PASS 行にも red_needle 文字列 (「★NG★ U1b」等) が引用されるため、
    # 除かねば緑の行が所見を埋めて肝心の非 PASS 行を head -8 から押し出す
    # (2026-07-26 cmd_1355b の E2E 実射で発見)
    detail="$(printf '%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5" | grep -E '\[(IGNORED|UNTRACKED|MISSING|COUNT|EMPTY-DIR|UNREGISTERED)\]|★NG★|UNDETERMINED|陽性対照' | grep -vE '^\s*ok\s' | head -8 | awk '{printf "%s・", $0}' | sed 's/: /：/g')"
    hooknote=""
    [ "$hook_rc" -ne 0 ] && hooknote="★pre-commit shim不在=install_gate_hooks.sh で再据付せよ★ "
    wirenote=""
    [ "$wiring_rc" -ne 0 ] && wirenote="★stall_watchdog の cron 配線不在=帳簿漏れの番人が誰にも呼ばれておらぬ (cmd_1359)★ "
    msg="【gate_nightly警告】沈黙落とし穴gate非PASS=gate-1(commit捕捉)=$(verdict "$rc1")/gate-2(変異台帳)=$(verdict "$rc2")/台帳登録検知=$(verdict "$rc3")/backend台帳(cmd_1355)=$(verdict "$rc4")/backend登録検知=$(verdict "$rc5")。${hooknote}${wirenote}所見=${detail} 処方=docs/content/ops/cmd_1352_silent_pitfall_gates.md (backend側は cmd_1355_backend_registry_extension.md) を見て名指しされた項目を是正し、対応する gate の再走で緑を確認せよ。"
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly \
        || echo "[gate_nightly] WARN: 家老への inbox_write が失敗 (次回 cron で再警告)" >&2
fi

echo "── [gate_nightly] 終了 gate-1=$(verdict "$rc1") gate-2=$(verdict "$rc2") 登録検知=$(verdict "$rc3") backend台帳=$(verdict "$rc4") backend登録検知=$(verdict "$rc5") hook=$([ "$hook_rc" -eq 0 ] && echo OK || echo MISSING) 配線=$([ "$wiring_rc" -eq 0 ] && echo OK || echo MISSING) ──"
if [ "$rc1" -eq 1 ] || [ "$rc2" -eq 1 ] || [ "$rc3" -eq 1 ] || [ "$rc4" -eq 1 ] || [ "$rc5" -eq 1 ]; then exit 1; fi
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ]; then exit 2; fi
exit 0
