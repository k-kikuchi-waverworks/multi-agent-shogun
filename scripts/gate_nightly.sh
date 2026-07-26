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

# ★木の点呼 (cmd_1374) の材料★: 各 gate が【実際に撃った】repo-root をここへ書き足す。
# ★宣言でなく実績を記す★ = gate の呼び出し行を消せばその木は記録されず、点呼が
# 「見ておらぬ牙持ちの木」として名指す。「配線を消したのに watched のまま」が起こり得ぬ形。
WATCHED_LIST="$(mktemp -t gate_watched.XXXXXX)"
trap 'rm -f "$WATCHED_LIST"' EXIT
watched() { printf '%s\n' "$1" >> "$WATCHED_LIST"; }

# --committed = HEAD blob を正とする (fresh clone が受け取る中身の検分。作業ツリーを信ぜぬ
#  = 軍師二号が cmd_1349 QC で示した流儀。index 視点は pre-commit hook 側が受け持つ)
out1="$(bash "$SCRIPT_DIR/scripts/gate_artifact_capture.sh" --all --committed 2>&1)"; rc1=$?
out2="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" 2>&1)"; rc2=$?
# gate-2 付帯 (cmd_1352b): 台帳登録検知 — 変異testらしき file が台帳に無ければ名指しで警告
out3="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage 2>&1)"; rc3=$?
watched "$SCRIPT_DIR"

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
    watched "$BACKEND_ROOT"
else
    rc4=2; out4="[gate-2 backend] UNDETERMINED: backend 台帳が見えぬ ($BACKEND_REG) = submodule 未init / path 違いの疑い。検分できておらぬは緑ではない"
    rc5=2; out5="[gate-2 backend coverage] UNDETERMINED: backend 台帳が見えぬ ($BACKEND_REG) = 同上"
fi

# ── ★app 本体 台帳延長 (cmd_1374)★ ─────────────────────────────────────────────
# ★backend (子) は見ておったが、その親である app 本体は【どの gate も見ておらぬ】★
# 木であった (cmd_1370 A-3 で実測 = 盲ですらなく、そもそも走査されておらぬ)。
# ★登録検知のみ★を撃つ = app 台帳の mutations: は空ゆえ replay を撃つと
# 「台帳 0 件 = 永久 UNDETERMINED」になり ★免除より悪い形★ (毎朝鳴って誰も消せぬ) になる。
# ⇒ 実体のある変異が 1 件でも登録された時に replay をここへ足すのが筋 (docs に明記)。
APP_ROOT="${GATE_APP_ROOT:-$HOME/aituber-project}"
APP_ROOT="$(readlink -f "$APP_ROOT" 2>/dev/null || echo "$APP_ROOT")"
APP_REG="$APP_ROOT/config/mutation_registry.yaml"
echo "[gate_nightly] app 本体 台帳 = $APP_REG"
if [ -f "$APP_REG" ]; then
    out6="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage --registry "$APP_REG" --repo-root "$APP_ROOT" 2>&1)"; rc6=$?
    watched "$APP_ROOT"
else
    rc6=2; out6="[gate-2 app coverage] UNDETERMINED: app 本体の台帳が見えぬ ($APP_REG) = path 違い / disk 喪失の疑い。検分できておらぬは緑ではない"
fi
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5" "$out6"

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

# ★配られておらぬ道具の検知 (cmd_1367)★: 上の「配線消失検知」は【呼ぶ者が居るか】を見る。
# 本検査はその裏返し = ★呼ばれる者が fresh clone へ配られるか★。
# whitelist 型 .gitignore ゆえ道具は既定で除外され、名指しを忘れると
# 「手元では動くが clone には無い」形で静かに落ちる (本日 五号が gpu_sidecar_stop.sh で発見)。
# 同じ穴が cmd_1280/1339/1354/1355/1363 と5回別々に開いておるゆえ、族として毎朝見る。
undist_out="$(bash "$SCRIPT_DIR/scripts/gate_undistributed_tooling.sh" 2>&1)"; undist_rc=$?
printf '%s\n' "$undist_out"

# ★木の点呼 (cmd_1374)★: 上の各 gate は【見ておる木の中】を検分する。
# 本層はその一段外 = ★そもそも どの gate も見ておらぬ木★ を名指す。
# ★見ておらぬ場所には、盲であることすら分からぬ★ — ゆえに「見ておらぬ木の数」を毎朝出す。
# 分母は system 自身の登録 (config/projects.yaml) + 実際に撃った木 + その submodule。
census_out="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --tree-census \
    --watched-file "$WATCHED_LIST" 2>&1)"; census_rc=$?
printf '%s\n' "$census_out"

verdict() { case "$1" in 0) echo PASS;; 1) echo FAIL;; *) echo UNDETERMINED;; esac; }

# ★切り詰めたなら【切り詰めたと言え】★ (cmd_1367 N1・軍師一号の差し戻し)
#   本 script は所見を 3 箇所で head により畳んでおるが、いずれも ★入り切らなんだ分を
#   黙って捨てておった★。軍師の実射 = 実在の道具 3 本を落とすと gate は 3 本とも掴むのに、
#   家老へ届く文面には 2 本しか載らず ★残数の表示も無かった★ (重複行が枠を食うた)。
#   ⇒ ★黙って捨てる要約は、読む者に「これが全部だ」と誤読させる★ =
#     本日ずっと潰してきた【数字だけ見せて範囲を黙る】の同族ゆえ、残数を必ず添える。
#   (重複そのものは gate_undistributed_tooling.sh 側で 1 道具 1 行へ畳んで断ってある)
#   ★1行化の作法は従前どおり★ = awk で連結 (tr は多byte を割る)・": " は全角へ (YAML 安全)。
fold_lines() {
    local limit="$1" all n
    all="$(cat)"
    n="$(printf '%s' "$all" | grep -c . || true)"
    [ "$n" -eq 0 ] && return 0
    printf '%s' "$all" | head -n "$limit" | awk '{printf "%s・", $0}' | sed 's/: /：/g'
    [ "$n" -gt "$limit" ] && printf '★他 %s 行は畳んだ (全 %s 行・log を見よ)★・' "$((n - limit))" "$n"
    return 0
}

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$rc6" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ] || [ "$undist_rc" -ne 0 ] || [ "$census_rc" -ne 0 ]; then
    # 警告は1行に畳む (inbox message の YAML 安全のため改行・コロン+空白を避ける)
    # 行連結は awk で行う (tr '\n' '・' は byte 置換ゆえ多byte文字の先頭1byteのみを埋め
    # 不正 UTF-8 を inbox へ混入させる — 2026-07-26 実測で発見した既存バグの是正)
    # PASS 行は除外する: PASS 行にも red_needle 文字列 (「★NG★ U1b」等) が引用されるため、
    # 除かねば緑の行が所見を埋めて肝心の非 PASS 行を head -8 から押し出す
    # (2026-07-26 cmd_1355b の E2E 実射で発見)
    detail="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5" "$out6" | grep -E '\[(IGNORED|UNTRACKED|MISSING|COUNT|EMPTY-DIR|UNREGISTERED|WAIVER-EXPIRED)\]|★NG★|UNDETERMINED|陽性対照' | grep -vE '^\s*ok\s' | fold_lines 8)"
    hooknote=""
    [ "$hook_rc" -ne 0 ] && hooknote="★pre-commit shim不在=install_gate_hooks.sh で再据付せよ★ "
    wirenote=""
    [ "$wiring_rc" -ne 0 ] && wirenote="★stall_watchdog の cron 配線不在=帳簿漏れの番人が誰にも呼ばれておらぬ (cmd_1359)★ "
    undistnote=""
    # 所見は undist 側の出力から直に採る (上の detail は gate-1/2 の out しか畳んでおらぬ)。
    # ★角括弧つきの判定行のみを拾う★ = 内訳行にも "★UNDISTRIBUTED=1★" の語が出るゆえ、
    #   語で拾うと集計行が所見を埋め ★何が配られておらぬのかを名指しできぬ警告★ になる
    #   (2026-07-26 worktree 実射で実測。cmd_1355b で PASS 行が所見を押し出したのと同型)。
    [ "$undist_rc" -ne 0 ] && undistnote="★配られておらぬ道具あり (cmd_1367)=$(printf '%s' "$undist_out" | grep -E '\[(UNDISTRIBUTED|FAIL|UNDETERMINED)\]' | fold_lines 4)★ "
    censusnote=""
    # ★点呼の所見も直に採る★ = detail は gate-1/2 の out しか畳んでおらぬゆえ、
    #   足さねば「点呼が赤いのに、どの木が見られておらぬか名指しできぬ警告」になる
    #   (cmd_1367 の配布 gate で実際に踏んだ轍。角括弧つきの判定行のみを拾う)。
    [ "$census_rc" -ne 0 ] && censusnote="★どの gate も見ておらぬ木あり (cmd_1374)=$(printf '%s' "$census_out" | grep -E '\[(UNWATCHED|免除期限切れ)\]|木の点呼\] (FAIL|UNDETERMINED)' | fold_lines 4)★ "
    msg="【gate_nightly警告】沈黙落とし穴gate非PASS=gate-1(commit捕捉)=$(verdict "$rc1")/gate-2(変異台帳)=$(verdict "$rc2")/台帳登録検知=$(verdict "$rc3")/backend台帳(cmd_1355)=$(verdict "$rc4")/backend登録検知=$(verdict "$rc5")/app登録検知(cmd_1374)=$(verdict "$rc6")/配布(cmd_1367)=$(verdict "$undist_rc")/木の点呼(cmd_1374)=$(verdict "$census_rc")。${hooknote}${wirenote}${undistnote}${censusnote}所見=${detail} 処方=docs/content/ops/cmd_1352_silent_pitfall_gates.md (backend側は cmd_1355_backend_registry_extension.md) を見て名指しされた項目を是正し、対応する gate の再走で緑を確認せよ。"
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly \
        || echo "[gate_nightly] WARN: 家老への inbox_write が失敗 (次回 cron で再警告)" >&2
fi

echo "── [gate_nightly] 終了 gate-1=$(verdict "$rc1") gate-2=$(verdict "$rc2") 登録検知=$(verdict "$rc3") backend台帳=$(verdict "$rc4") backend登録検知=$(verdict "$rc5") app登録検知=$(verdict "$rc6") hook=$([ "$hook_rc" -eq 0 ] && echo OK || echo MISSING) 配線=$([ "$wiring_rc" -eq 0 ] && echo OK || echo MISSING) 配布=$(verdict "$undist_rc") 木の点呼=$(verdict "$census_rc") ──"
if [ "$rc1" -eq 1 ] || [ "$rc2" -eq 1 ] || [ "$rc3" -eq 1 ] || [ "$rc4" -eq 1 ] || [ "$rc5" -eq 1 ] || [ "$rc6" -eq 1 ] || [ "$undist_rc" -eq 1 ] || [ "$census_rc" -eq 1 ]; then exit 1; fi
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$rc6" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ] || [ "$undist_rc" -ne 0 ] || [ "$census_rc" -ne 0 ]; then exit 2; fi
exit 0
