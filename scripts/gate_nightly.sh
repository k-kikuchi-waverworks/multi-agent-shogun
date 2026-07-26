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
# ★撃とうとした木 (cmd_1374b ③・軍師一号の差し戻し)★:
#   watched は ★成功の枝の中でしか書かれぬ★ ゆえ、台帳不在などで黙って飛ばした木は
#   点呼から ★「未監視」ですらなく【存在せぬ】として消えておった★
#   (軍師一号の実測 = fresh clone の素の姿で点呼が PASS rc0 を返し、app牙12/backend牙14 が
#    分母に一度も現れなんだ)。★呼び出し行が在った事実★も実績ゆえ、撃つ前に必ず書き留める。
ATTEMPTED_LIST="$(mktemp -t gate_attempted.XXXXXX)"
trap 'rm -f "$WATCHED_LIST" "$ATTEMPTED_LIST"' EXIT
watched()   { printf '%s\n' "$1" >> "$WATCHED_LIST"; }
attempted() { printf '%s\n' "$1" >> "$ATTEMPTED_LIST"; }
# 台帳に実体のある変異が 1 件でも在るか (0 件なら replay は「台帳0件=永久UNDETERMINED」になる)
has_mutations() { python3 - "$1" <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    sys.exit(1)
sys.exit(0 if (d.get("mutations") or []) else 1)
PY
}

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
attempted "$BACKEND_ROOT"   # ★撃とうとした事実を先に記す (下で黙って飛ばしても点呼から消えぬ)★
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
attempted "$APP_ROOT"
if [ -f "$APP_REG" ]; then
    out6="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage --registry "$APP_REG" --repo-root "$APP_ROOT" 2>&1)"; rc6=$?
    # ★cmd_1374b ⑤ (軍師一号の差し戻し)★: app は登録検知のみゆえ、★何もせぬ entry を1枚置けば
    #   coverage は「ok REGISTERED」と読み、その紙を捕まえる者が居らぬ★ =
    #   ★11行の紙で 08-31 の返済が作れてしまう★。
    #   ⇒ 台帳に entry が入った瞬間から replay も撃つ (紙なら baseline/mutate が UNDETERMINED か
    #     FAIL で名指される)。0 件の間は撃たぬ = 「台帳0件=永久UNDETERMINED」(免除より悪い形) を避ける。
    if has_mutations "$APP_REG"; then
        out6b="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --registry "$APP_REG" --repo-root "$APP_ROOT" 2>&1)"; rc6b=$?
    else
        rc6b=0; out6b="[gate-2 app replay] 台帳に変異 entry が 0 件ゆえ replay は撃たぬ (★entry が 1 件でも入れば翌朝から自動で撃つ★ = 何もせぬ紙で免除を返せぬ形)"
    fi
    watched "$APP_ROOT"
else
    rc6=2; out6="[gate-2 app coverage] UNDETERMINED: app 本体の台帳が見えぬ ($APP_REG) = path 違い / disk 喪失の疑い。検分できておらぬは緑ではない"
    rc6b=2; out6b="[gate-2 app replay] UNDETERMINED: 同上 (台帳が見えぬゆえ replay も撃てておらぬ)"
fi

# ── ★waverworks web repo 台帳延長 (cmd_1374 A-1)★ ─────────────────────────────
# 木の点呼が掘り出した2本目の未監視木 (牙 1 件 = scripts/check-shippable-theme.py)。
# ★台帳は shogun 側 (config/mutation_registry.web.yaml) に置く★ =
#   web repo は /mnt/c/Users 配下 (殿 CLAUDE.md の変更禁止領域) ゆえ、そこへ新しい機構を
#   置く道を採らず、runner を --repo-root で跨がせる (台帳 file と repo-root は 1 対 1)。
WEB_ROOT="${GATE_WEB_ROOT:-/mnt/c/Users/k-kikuchi/development/waverworks/common/wp-content/themes/waverworks-base-for-wp}"
WEB_ROOT="$(readlink -f "$WEB_ROOT" 2>/dev/null || echo "$WEB_ROOT")"
WEB_REG="$SCRIPT_DIR/config/mutation_registry.web.yaml"
echo "[gate_nightly] web 台帳 = $WEB_REG (repo-root=$WEB_ROOT)"
attempted "$WEB_ROOT"
if [ -f "$WEB_REG" ] && [ -d "$WEB_ROOT" ]; then
    out7="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --registry "$WEB_REG" --repo-root "$WEB_ROOT" 2>&1)"; rc7=$?
    out8="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage --registry "$WEB_REG" --repo-root "$WEB_ROOT" 2>&1)"; rc8=$?
    watched "$WEB_ROOT"
else
    rc7=2; out7="[gate-2 web] UNDETERMINED: web 台帳 ($WEB_REG) か repo ($WEB_ROOT) が見えぬ = 検分できておらぬは緑ではない"
    rc8=2; out8="[gate-2 web coverage] UNDETERMINED: 同上"
fi
# ── ★ai-automate-engine 台帳延長 (cmd_1376)★ ────────────────────────────────
# 木の点呼が掘り出した3本目 = ★走査元 33 本に対し牙 0 件★ (cmd_1374 census) の木。
# ★0 件であった理由は二重であった (cmd_1376 実測)★:
#   ① 牙の勘定は sh/bash/py/bats を継ぎ、engine の試験 111 本は全て .ts で網の外
#   ② ★.ts を網へ入れても候補は 0 件のまま★ = D1/D2/D3 は @test / --selftest / def test_ を
#      見ており vitest の it( はどれにも当たらぬ ⇒ ★拡張子と検知規則の両方で盲★であった。
# ★台帳と牙は engine repo 側に置く★ = 牙は其の木と共に配られねば fresh clone に届かぬ
#   (web と扱いを違えた理由 = engine は我らが日々書き換えておる木ゆえ)。
# 牙の走らせ方は ★npm を一度も呼ばぬ形★ (node_modules/typescript で実 TS を落として撃つ) =
#   R2-1 (WSL から npm 系は禁) と @esbuild が win32-x64 のみ、の両方を避けておる。
ENGINE_ROOT="${GATE_ENGINE_ROOT:-/mnt/c/Users/k-kikuchi/development/ai-automate-engine}"
ENGINE_ROOT="$(readlink -f "$ENGINE_ROOT" 2>/dev/null || echo "$ENGINE_ROOT")"
ENGINE_REG="$ENGINE_ROOT/config/mutation_registry.yaml"
echo "[gate_nightly] engine 台帳 = $ENGINE_REG"
export GATE_ENGINE_ROOT="$ENGINE_ROOT"   # 牙が typescript を見つける口 (scratch からは repo が見えぬゆえ)
attempted "$ENGINE_ROOT"
if [ -f "$ENGINE_REG" ]; then
    out9="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --registry "$ENGINE_REG" --repo-root "$ENGINE_ROOT" 2>&1)"; rc9=$?
    out10="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage --registry "$ENGINE_REG" --repo-root "$ENGINE_ROOT" 2>&1)"; rc10=$?
    watched "$ENGINE_ROOT"
else
    rc9=2; out9="[gate-2 engine] UNDETERMINED: engine 台帳が見えぬ ($ENGINE_REG) = path 違い / disk 喪失の疑い。検分できておらぬは緑ではない"
    rc10=2; out10="[gate-2 engine coverage] UNDETERMINED: 同上"
fi
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5" "$out6" "$out6b" "$out7" "$out8" "$out9" "$out10"

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
    --watched-file "$WATCHED_LIST" --attempted-file "$ATTEMPTED_LIST" 2>&1)"; census_rc=$?
printf '%s\n' "$census_out"

# ★通知路の生死 (cmd_1381 段3)★: 上の各層は【我らの gate が働いておるか】を見る。
# 本層は其の外側 = ★殿へ物を届ける経路そのものが生きておるか★。
# ★通知は3ヶ月近く一度も届かず、気づいたのは【偶然 2.26MB の log を掘ったから】である★
#   (痕跡は 44,483 行中ただ1行・時刻すら無し)。★偶然に頼る形を、毎朝の番人へ移す★。
# ★壊れた通知路の故障を、その通知路で報せてはならぬ★ ゆえ、engine の ntfy は 1bit も通らず
#   別実装 (python)・別 process (cron)・別 repo (shogun) の此処が名指し、家老 inbox へ出る。
# ★三値を潰さぬ★ = 記録が【無い】のは「据わっておらぬ (未検分)」であり「届かなんだ」ではない
#   (engine の initStaleCleanup は process 起動時1度だけ・HMR では再登録されぬ = 軍師二号 §4)。
ntfy_out="$(python3 "$SCRIPT_DIR/scripts/gate_ntfy_alive.py" 2>&1)"; ntfy_rc=$?
printf '%s\n' "$ntfy_out"

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

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$rc6" -ne 0 ] || [ "$rc6b" -ne 0 ] || [ "$rc7" -ne 0 ] || [ "$rc8" -ne 0 ] || [ "$rc9" -ne 0 ] || [ "$rc10" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ] || [ "$undist_rc" -ne 0 ] || [ "$census_rc" -ne 0 ] || [ "$ntfy_rc" -ne 0 ]; then
    # 警告は1行に畳む (inbox message の YAML 安全のため改行・コロン+空白を避ける)
    # 行連結は awk で行う (tr '\n' '・' は byte 置換ゆえ多byte文字の先頭1byteのみを埋め
    # 不正 UTF-8 を inbox へ混入させる — 2026-07-26 実測で発見した既存バグの是正)
    # PASS 行は除外する: PASS 行にも red_needle 文字列 (「★NG★ U1b」等) が引用されるため、
    # 除かねば緑の行が所見を埋めて肝心の非 PASS 行を head -8 から押し出す
    # (2026-07-26 cmd_1355b の E2E 実射で発見)
    # ★cmd_1376: web (out7/out8) と engine (out9/out10) を所見の分母へ入れる★ =
    #   従前は gate-1/2 と backend/app の out しか畳んでおらず、★web/engine が非 PASS でも
    #   家老の警告には「UNDETERMINED」の verdict だけが出て【何が起きたか】が載らなんだ★
    #   (cmd_1367 N1 / cmd_1355b で二度直した「名指しできぬ警告」の同族。三度目ゆえ族として断つ)。
    detail="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$out1" "$out2" "$out3" "$out4" "$out5" "$out6" "$out7" "$out8" "$out9" "$out10" | grep -E '\[(IGNORED|UNTRACKED|MISSING|COUNT|EMPTY-DIR|UNREGISTERED|WAIVER-EXPIRED)\]|★NG★|UNDETERMINED|陽性対照' | grep -vE '^\s*ok\s' | fold_lines 8)"
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
    ntfynote=""
    # ★所見を直に採る (cmd_1381 段3)★ = detail は gate-1/2 の out しか畳んでおらぬゆえ、
    #   足さねば「通知路が赤いのに、何が起きたか名指しできぬ警告」になる
    #   (cmd_1367 の配布 gate・cmd_1374 の点呼で二度踏んだ轍。三度目は踏まぬ)。
    #   ★角括弧つきの判定行のみを拾う★ = 本文にも語が出るゆえ、語で拾えば集計行が所見を埋める。
    [ "$ntfy_rc" -ne 0 ] && ntfynote="★殿への通知路が緑でない (cmd_1381)=$(printf '%s' "$ntfy_out" | grep -E '\[NTFY-(DEAD|UNSEATED|STALE|SHAPE|CALENDAR)\]' | fold_lines 3)★ "
    msg="【gate_nightly警告】沈黙落とし穴gate非PASS=gate-1(commit捕捉)=$(verdict "$rc1")/gate-2(変異台帳)=$(verdict "$rc2")/台帳登録検知=$(verdict "$rc3")/backend台帳(cmd_1355)=$(verdict "$rc4")/backend登録検知=$(verdict "$rc5")/app登録検知(cmd_1374)=$(verdict "$rc6")/app台帳=$(verdict "$rc6b")/web台帳(cmd_1374 A-1)=$(verdict "$rc7")/web登録検知=$(verdict "$rc8")/engine台帳(cmd_1376)=$(verdict "$rc9")/engine登録検知=$(verdict "$rc10")/配布(cmd_1367)=$(verdict "$undist_rc")/木の点呼(cmd_1374)=$(verdict "$census_rc")/殿への通知路(cmd_1381)=$(verdict "$ntfy_rc")。${hooknote}${wirenote}${undistnote}${censusnote}${ntfynote}所見=${detail} 処方=docs/content/ops/cmd_1352_silent_pitfall_gates.md (backend側は cmd_1355_backend_registry_extension.md) を見て名指しされた項目を是正し、対応する gate の再走で緑を確認せよ。"
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly \
        || echo "[gate_nightly] WARN: 家老への inbox_write が失敗 (次回 cron で再警告)" >&2
fi

echo "── [gate_nightly] 終了 gate-1=$(verdict "$rc1") gate-2=$(verdict "$rc2") 登録検知=$(verdict "$rc3") backend台帳=$(verdict "$rc4") backend登録検知=$(verdict "$rc5") app登録検知=$(verdict "$rc6") app台帳=$(verdict "$rc6b") web台帳=$(verdict "$rc7") web登録検知=$(verdict "$rc8") engine台帳=$(verdict "$rc9") engine登録検知=$(verdict "$rc10") hook=$([ "$hook_rc" -eq 0 ] && echo OK || echo MISSING) 配線=$([ "$wiring_rc" -eq 0 ] && echo OK || echo MISSING) 配布=$(verdict "$undist_rc") 木の点呼=$(verdict "$census_rc") 通知路=$(verdict "$ntfy_rc") ──"
if [ "$rc1" -eq 1 ] || [ "$rc2" -eq 1 ] || [ "$rc3" -eq 1 ] || [ "$rc4" -eq 1 ] || [ "$rc5" -eq 1 ] || [ "$rc6" -eq 1 ] || [ "$rc6b" -eq 1 ] || [ "$rc7" -eq 1 ] || [ "$rc8" -eq 1 ] || [ "$rc9" -eq 1 ] || [ "$rc10" -eq 1 ] || [ "$undist_rc" -eq 1 ] || [ "$census_rc" -eq 1 ] || [ "$ntfy_rc" -eq 1 ]; then exit 1; fi
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ] || [ "$rc4" -ne 0 ] || [ "$rc5" -ne 0 ] || [ "$rc6" -ne 0 ] || [ "$rc6b" -ne 0 ] || [ "$rc7" -ne 0 ] || [ "$rc8" -ne 0 ] || [ "$rc9" -ne 0 ] || [ "$rc10" -ne 0 ] || [ "$hook_rc" -ne 0 ] || [ "$wiring_rc" -ne 0 ] || [ "$undist_rc" -ne 0 ] || [ "$census_rc" -ne 0 ] || [ "$ntfy_rc" -ne 0 ]; then exit 2; fi
exit 0
