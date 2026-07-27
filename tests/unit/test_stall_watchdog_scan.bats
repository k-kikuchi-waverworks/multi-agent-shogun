#!/usr/bin/env bats
# test_stall_watchdog_scan.bats — cmd_552 Phase 3 Watchdog scan unit tests.
#
# Scope: scripts/stall_watchdog_scan.{sh,py} report↔task YAML 突合 scan.
# Covers positive detection + four false-positive guards + multi-doc / nested /
# primary_task variants.
#
# 契約変更 (cmd_1356 follow-up・家老裁定 2026-07-26 09:24):
#   hit 0 件時は【無出力】でなく【分母を名指しする1行】を印字する =
#   `[stall_watchdog] 帳簿漏れ hit なし。assigned=N`。
#   無出力の契約は「分母0 (status drift で何も見えておらぬ = 盲目)」と「全員健全」を
#   log 上区別できぬ (idle_revive eligible=N と同型の観測性欠落)。負例 test は
#   「hit が無い」+「分母が正しい」の両方を assert する (契約の削除でなく新契約 green)。
#   分母印字の変異登録 = MUT-0552-003 (test_stall_watchdog_status_normalize.bats T-SWD-005)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # ★番人は cron (15分毎) で現に走っておる★ ⇒ 変異は【複写】へ当てる
    # (★半端な状態の本番を走らせぬ★)。
    # ★口は三 suite で 1 つ = STALL_SCAN_ROOT★ — 名を suite ごとに分ければ、
    # ★片方にだけ口が開いた状態★ が生まれ、次に来た者が必ず踏む (拙者が現に踏んだ)。
    export STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$PROJECT_ROOT}"
    export SCAN_SH="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.sh"
    export SCAN_PY="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    [ -f "$SCAN_SH" ] || return 1
    [ -f "$SCAN_PY" ] || return 1
    "$PROJECT_ROOT/.venv/bin/python3" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_watchdog.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_write_task() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: ${task_id}
  parent_cmd: ${parent_cmd}
  assigned_to: ${agent}
  status: ${status}
EOF
}

_write_report_flat() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4" ts="$5"
    cat > "$Q/reports/${agent}_report.yaml" <<EOF
worker_id: ${agent}
task_id: ${task_id}
parent_cmd: ${parent_cmd}
status: ${status}
timestamp: "${ts}"
EOF
}

_write_report_nested() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4" ts="$5"
    cat > "$Q/reports/${agent}_report.yaml" <<EOF
report:
  task_id: ${task_id}
  parent_cmd: ${parent_cmd}
  agent: ${agent}
  status: ${status}
  timestamp: "${ts}"
EOF
}

_ts_minutes_ago() {
    local minutes="$1"
    date -d "${minutes} minutes ago" +"%Y-%m-%dT%H:%M:%S"
}

# =============================================================================
# T-001: 正例 — assigned + completed + 31 分経過 → HIT 1 件
# =============================================================================
@test "T-001: positive — assigned task + completed report 31min old → 1 hit" {
    local ts="$(_ts_minutes_ago 31)"
    _write_task ashigaru3 subtask_demo_positive cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_positive cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_demo_positive"* ]]
    [[ "$output" == *"REPORT_STATUS=completed"* ]]
}

# =============================================================================
# T-002: 負例 — task status=done は scan 対象外
# =============================================================================
@test "T-002: negative — task status=done is skipped (denominator assigned=0)" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_demo_done cmd_999 done
    _write_report_flat ashigaru3 subtask_demo_done cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=0"* ]]
}

# =============================================================================
# T-003: 負例 — report status=in_progress は完遂未達ゆえ skip
# =============================================================================
@test "T-003: negative — report status=in_progress is not completion (assigned=1 visible)" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_demo_ip cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_ip cmd_999 in_progress "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=1"* ]]
}

# =============================================================================
# T-004: 負例 — 経過 15 分は閾値未満ゆえ skip
# =============================================================================
@test "T-004: negative — elapsed 15min below threshold 30 (assigned=1 visible)" {
    local ts="$(_ts_minutes_ago 15)"
    _write_task ashigaru3 subtask_demo_fresh cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_fresh cmd_999 done "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=1"* ]]
}

# =============================================================================
# T-005: 負例 — task_id 不一致 (報告は別 task の記録) は skip
# =============================================================================
@test "T-005: negative — task_id mismatch between task YAML and report (assigned=1 visible)" {
    local ts="$(_ts_minutes_ago 60)"
    _write_task ashigaru3 subtask_current cmd_999 assigned
    _write_report_flat ashigaru3 subtask_previous cmd_998 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=1"* ]]
}

# =============================================================================
# T-006: nested (report:) 形式 report でも正例検出
# =============================================================================
@test "T-006: positive — nested 'report:' wrapper is recognised" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_nested cmd_999 assigned
    _write_report_nested ashigaru3 subtask_nested cmd_999 done "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_nested"* ]]
    [[ "$output" == *"REPORT_STATUS=done"* ]]
}

# =============================================================================
# T-007: 複数 doc (`---`) report から timestamp 最新 entry を採用
# =============================================================================
@test "T-007: positive — multi-doc report picks latest by timestamp" {
    local ts_old="$(_ts_minutes_ago 180)"
    local ts_new="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_new_task cmd_999 assigned
    cat > "$Q/reports/ashigaru3_report.yaml" <<EOF
worker_id: ashigaru3
task_id: subtask_old_task
parent_cmd: cmd_998
status: completed
timestamp: "${ts_old}"
---
worker_id: ashigaru3
task_id: subtask_new_task
parent_cmd: cmd_999
status: completed
timestamp: "${ts_new}"
EOF

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_new_task"* ]]
}

# =============================================================================
# T-008: gunshi primary_task キー名でも正例検出
# =============================================================================
@test "T-008: positive — gunshi 'primary_task' key matches task_id" {
    local ts="$(_ts_minutes_ago 60)"
    _write_task gunshi subtask_qc_demo cmd_999 assigned
    cat > "$Q/reports/gunshi_report.yaml" <<EOF
report:
  primary_task: subtask_qc_demo
  parent_cmd: cmd_999
  agent: gunshi
  status: done
  timestamp: "${ts}"
EOF

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=gunshi"* ]]
    [[ "$output" == *"TASK_ID=subtask_qc_demo"* ]]
}

# =============================================================================
# T-009: JSON 出力形式
# =============================================================================
@test "T-009: --json emits JSON array with hit fields" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_json cmd_999 assigned
    _write_report_flat ashigaru3 subtask_json cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"agent\": \"ashigaru3\""* ]]
    [[ "$output" == *"\"task_id\": \"subtask_json\""* ]]
    [[ "$output" == *"\"elapsed_min\":"* ]]
}

# =============================================================================
# T-010: report YAML 不存在は 警告なしで skip
# =============================================================================
@test "T-010: missing report YAML is gracefully skipped (assigned=1 visible)" {
    _write_task ashigaru3 subtask_no_report cmd_999 assigned
    # no report file written

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=1"* ]]
}

# =============================================================================
# T-011 (cmd_1394 同族・家老 03:31): ★読めぬ report を【健全】と読ませぬ★
#
# ★本 scan の実害は idle_revive とは向きが逆である★:
#   idle_revive     = 読めぬ物へ ★撃ってしまう★ (偽陽性・cmd_1394 (3) で塞いだ)
#   stall_watchdog  = 読めぬ物を ★見逃す★ (偽陰性) =
#     ★真の帳簿漏れが「report が壊れておる」という別の理由で永久に鳴らぬ★
#   ⇒ 従来は parse 落ちが (None, None) で返り、★「此の task の記録が無い」と
#     区別がつかず黙って skip★ = log は「帳簿漏れ hit なし」と申しておった。
# =============================================================================
@test "T-011: an unreadable report is NAMED, never counted as healthy (silent skip is the disease)" {
    _write_task ashigaru3 subtask_unreadable cmd_999 assigned
    # ★YAML として壊れた report★ (tab 混入 + 閉じぬ引用符 = safe_load_all が上げる)
    printf 'report:\n\tstatus: "done\n  task_id: subtask_unreadable\n' \
        > "$Q/reports/ashigaru3_report.yaml"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "report YAML parse failed"
    # ★外したことを、外した其の走行で申す★
    echo "$output" | grep -q "ACTION=report_unreadable AGENT=ashigaru3 TASK_ID=subtask_unreadable"
    echo "$output" | grep -q "★健全と読むな★"
    echo "$output" | grep -q "書き手 ashigaru3"
    # ★hit 0 の行が【全員健全】と読めぬ形になっておる★
    echo "$output" | grep -q "読めぬreport除外=1"
    echo "$output" | grep -q "判じられなんだ agent が居る"
    # ★帳簿漏れとしては鳴らしておらぬ★ (判じられぬのに漏れと断ずるのは別の嘘)
    if echo "$output" | grep -q "^AGENT=ashigaru3 TASK_ID=subtask_unreadable PARENT_CMD="; then
        echo "★判じられぬ物を hit として鳴らしておる★" >&2
        echo "$output" >&2
        return 1
    fi
}

# =============================================================================
# T-012 (T-011 の逆向き): ★除外が過剰でない★
# 同じ盤面で report が★健全★なら従前どおり hit が鳴り、読めぬ除外は 0 と名乗る。
# (これが無ければ「全部を読めぬ扱いにして黙る」実装でも T-011 は緑になる)
# =============================================================================
@test "T-012: a healthy report on the same board still hits, and the exclusion count says zero" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_readable cmd_999 assigned
    _write_report_flat ashigaru3 subtask_readable cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AGENT=ashigaru3"
    echo "$output" | grep -q "TASK_ID=subtask_readable"
    if echo "$output" | grep -q "ACTION=report_unreadable"; then
        echo "★健全な report を【読めぬ】と申しておる = 除外が過剰★" >&2
        echo "$output" >&2
        return 1
    fi
}

# =============================================================================
# T-013: ★json の口でも黙らぬ★
# hits だけを吐けば、読めなんだ agent は ★json の読み手にとって存在せぬ★ =
# 同じ穴が口を変えて戻る (本夜 全軍で潰してきた「一段上で戻る」の形)。
# =============================================================================
@test "T-013: --json also declares the unreadable ones (the hole must not return via another mouth)" {
    _write_task ashigaru3 subtask_json_unreadable cmd_999 assigned
    printf 'report:\n\tstatus: "done\n  task_id: subtask_json_unreadable\n' \
        > "$Q/reports/ashigaru3_report.yaml"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30 --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ACTION=report_unreadable AGENT=ashigaru3"
    echo "$output" | grep -q "判じられぬゆえ hits に載らぬ"
}

# =============================================================================
# T-014 (家老 04:20 の規の訂正・★契約の値は焼き付けよ★)
#
# ★第三の盲がある★ — 家老が並べた表は二つを分けた:
#   ★他所から導かれる【事実】★ を焼き付ける → 他人が動かせば黙って偽になる (いけぬ)
#   ★我らが決めた【契約の値】★ を焼き付ける → 誰かが動かせば必ず赤くなる (よい)
# ★然るに本 suite は【契約の値を引数で上書きして】撃っておった★ (--threshold-min 30) =
#   ★焼き付けても居らず、実行時に読んでも居らぬ = 契約の値が試験の目の外に在る★。
# ★実測 (2026-07-27 04:0x)★= production の DEFAULT_THRESHOLD_MIN を 30 → 300 (10倍) へ
#   動かしても ★3 suite 32/32 が緑のまま★ であった = ★動かす変異に対して完全に盲★。
#
# ⇒ ★契約の値を此処に【宣言】し、production と突合する★。
#   ★意図して動かすなら、下の declared も直せ★ = ★其の一行が【意図の記録】になる★
#   (「黙って動いた」と「意図して動かした」を分ける唯一の場所)。
# =============================================================================
@test "T-014: the contract values are declared here and must match production (a moved default goes red)" {
    run "$PROJECT_ROOT/.venv/bin/python3" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("sw", os.environ["SCAN_PY"])
sw = importlib.util.module_from_spec(spec); spec.loader.exec_module(sw)

# ★契約 (焼き付ける = 動けば赤くなるのが正しい)★
DECLARED = {
    # 「report が完遂を名乗ってから N 分で帳簿漏れと判ずる」= cmd_552 以来の約束。
    # cron も同じ値を明示で渡しておる (*/15 … --threshold-min 30)。
    "DEFAULT_THRESHOLD_MIN": 30,
    # 「同じ漏れを鳴らし直すまで N 分 待つ」= ★常に赤い検知は無視されて死ぬ★ (cmd_1359)。
    "DEFAULT_COOLDOWN_MIN": 360,
    # ここから下は cmd_1450 (2026-07-28) で足した。
    # どちらも instructions/karo.md の「10分規律」から来ている。
    # 規律の中身 = 足軽の完遂報告が着いたら、家老は10分以内に軍師へ QC の任を起こす。
    # 10 は我らが決めた契約の値なので、動けば赤くなるのが正しい。
    # 足すまでの状態 = どちらもテストに一度も見られておらず、
    # 値を変えても全部 緑のままだった (軍師二号が cmd_1459 の検分で実測)。
    "QC_DEFAULT_THRESHOLD_MIN": 10,          # 軍師の inbox に未読のまま何分で鳴らすか (cmd_1454)
    "QC_LEDGER_DEFAULT_THRESHOLD_MIN": 10,   # 着地した report が台帳に載らないまま何分で鳴らすか (cmd_1459)
}
bad = []
for name, want in DECLARED.items():
    got = getattr(sw, name, None)
    if got != want:
        bad.append(f"{name}: 宣言 {want} ≠ 実装 {got}")
if bad:
    raise SystemExit(
        "★契約と実装が割れておる★ (どちらへも寄らず、割れを名乗る):\n  "
        + "\n  ".join(bad)
        + "\n  ⇒ 意図して動かしたのなら、本試験の DECLARED も直せ"
          " (其の一行が【意図の記録】になる)")
print("OK contract values match:", DECLARED)
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK contract values match"
}

# =============================================================================
# T-015 (cmd_1450・2026-07-28) — 宣言そのものが古びる形を塞ぐ
#
# 家老の問い: 「宣言に足す」だけで足りるか、宣言そのものが古びる形か。
# 答え = 古びる形である。T-014 の DECLARED は人が書き足す一覧なので、
# 明日 誰かが新しい定数を足しても、一覧の側は黙ったままになる。
#
# 実測 (2026-07-28 08:1x): 本体の直下にある数値の定数は4件。
# うち T-014 が見ていたのは2件だけだった。残り2件 (QC_DEFAULT_THRESHOLD_MIN /
# QC_LEDGER_DEFAULT_THRESHOLD_MIN) は、どちらも値を変えても全部 緑のままだった。
# 2件とも今日 足された物で、足した当人 (二号・三号) が一覧を直していない。
#
# これは今日ずっと出ている「名簿が古びる」と同じ族である。T-014 は
# 「値が動いたか」を見るが、「見るべき物が増えたか」は見ていなかった。
#
# ゆえに本試験は一覧の側を縛る。本体の直下にある数値の定数を機械で数え上げ、
# その全部が「契約として宣言されている」か「契約ではないと明示されている」かの
# どちらかであることを求める。どちらでもない定数が1件でもあれば赤くなる。
#
# 本試験が見ない範囲:
#   1. モジュール直下の、大文字の名前の、数値そのものの代入だけを見る。
#      式で組み立てた値・関数の既定引数・dict や tuple の中の数は見ない。
#   2. 「宣言されている」ことしか見ない。宣言された値が正しいかは T-014 の仕事である。
#   3. 見るのは stall_watchdog_scan.py だけである。
# =============================================================================
@test "T-015: every numeric constant is either declared as a contract or explicitly excluded (a new one goes red)" {
    run "$PROJECT_ROOT/.venv/bin/python3" - <<'PY'
import ast, os, re

scan_py = os.environ["SCAN_PY"]
bats_file = os.environ["BATS_TEST_FILENAME"]

# ── 本体の直下にある数値の定数を数え上げる ──
tree = ast.parse(open(scan_py, encoding="utf-8").read())
found = {}
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    for target in node.targets:
        if not (isinstance(target, ast.Name) and target.id.isupper()):
            continue
        v = node.value
        if isinstance(v, ast.Constant) and isinstance(v.value, (int, float)) \
           and not isinstance(v.value, bool):
            found[target.id] = v.value

# ── T-014 の宣言を、この file から読み取る (二重に書けば其方が古びるため) ──
body = open(bats_file, encoding="utf-8").read()
m = re.search(r"^DECLARED = \{(.*?)^\}", body, re.S | re.M)
if not m:
    raise SystemExit("T-014 の DECLARED を読み取れなかった。"
                     "書き方が変わったなら本試験の読み口も直せ")
declared = set(re.findall(r'^\s*"([A-Z0-9_]+)"\s*:', m.group(1), re.M))

# ★探し方が生きている証★ — 0 件しか読めなければ、この試験は
# 「全部 宣言されている」と黙って緑を返してしまう。先に落とす。
if len(declared) < 2:
    raise SystemExit(f"宣言を {len(declared)} 件しか読めなかった = 読み口が死んでいる")
if not found:
    raise SystemExit("本体から数値の定数を1件も拾えなかった = 読み口が死んでいる")

# ── 契約ではないと明示する物 = 名前 → 理由 の辞書 ──
#
# ★集合ではなく辞書である★ (cmd_1466・軍師一号の指摘で直した)。
# 集合だった時は、新しい定数の名前をここへ書き足すだけで全部 緑に戻った。
# ★緑へ戻す最も安い手が抜け道の側に在る形は、必ず使われる。★
#
# ★理由に何を書くかの基準 (1行)★:
#   「その値を動かした時に【何が変わるか】を書き、且つ【誰を起こすか・誰へ警報を上げるか】は
#     変わらないと言い切れること」。言い切れないなら契約であり、DECLARED へ足す物である。
#
NOT_A_CONTRACT = {}   # 今は1件も無い。足す時は "名前": "理由" の形で書く。
# 例: "BUF_SIZE": "読み込みの塊の大きさが変わるだけで、誰を起こすかは変わらない"

# ── 理由の側を検める ──
# ★機械が守れるのは【理由の形】だけである。理由が本当かは守れない (条6)。★
# 「特に無し」で通す道だけは塞ぐ。中身が嘘の理由は、これでも通る。
# ★短い語を入れてはならない★ — 「なし」を入れたら「見なしの割合が変わる」という
#   真っ当な理由が赤くなった (cmd_1466 実測)。★語は句として書く。★
_BANNED = ("特に無し", "特になし", "とくになし", "理由なし", "理由は無し",
           "未定", "暫定", "後で書く", "あとで書く", "todo", "n/a")
for _name, _why in sorted(NOT_A_CONTRACT.items()):
    if not isinstance(_why, str) or not _why.strip():
        raise SystemExit(f"NOT_A_CONTRACT の {_name} に理由が無い。"
                         "★名前だけで契約から外すことはできない★")
    _w = _why.strip()
    if len(_w) < 20:
        raise SystemExit(f"NOT_A_CONTRACT の {_name} の理由が短すぎる ({len(_w)} 字)。"
                         "動かした時に何が変わるかを書け")
    _low = _w.lower()
    for _b in _BANNED:
        if _b in _low:
            raise SystemExit(f"NOT_A_CONTRACT の {_name} の理由に「{_b}」が入っている。"
                             "★理由の欄を埋めるだけの言葉では契約から外せない★")
    if "変わ" not in _w:
        raise SystemExit(f"NOT_A_CONTRACT の {_name} の理由が「何が変わるか」を述べていない。"
                         "基準 = 動かした時に何が変わるかを書き、"
                         "誰を起こすか・誰へ警報を上げるかは変わらないと言い切ること")

# ── ★格下げを黙って通さない★ (cmd_1466・軍師一号が実測した重い方の抜け道) ──
# 名前だけを入れる抜け道は「新しい物を守り損ねる」だけだが、
# ★生きた契約を DECLARED から NOT_A_CONTRACT へ移す形は、守られている物の守りを黙って外せる。★
# ゆえに git の履歴を正本として、直前の版の DECLARED と今の NOT_A_CONTRACT を突き合わせる。
# ★射程 (条6)★: HEAD の版しか見ない。格下げと commit を同じ一手で済ませ、その間に一度も
#   試験を走らせなければ、次の版からは見えない。git が読めない時は緑にせず赤にする。
import subprocess

_repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(bats_file))))
_rel = os.path.relpath(os.path.abspath(bats_file), _repo)
_p = subprocess.run(["git", "-C", _repo, "show", f"HEAD:{_rel}"],
                    capture_output=True, text=True)
if _p.returncode != 0:
    raise SystemExit(
        "UNDETERMINED: 直前の版を git から読めなかったので、格下げを検められなかった。\n"
        f"  git の言い分: {_p.stderr.strip()[:200]}\n"
        "  ★検められなかったことを緑に混ぜないため、赤にしている★")
_m_prev = re.search(r"^DECLARED = \{(.*?)^\}", _p.stdout, re.S | re.M)
if not _m_prev:
    raise SystemExit("UNDETERMINED: 直前の版から DECLARED を読み取れなかった。読み口を直せ")
_prev_declared = set(re.findall(r'^\s*"([A-Z0-9_]+)"\s*:', _m_prev.group(1), re.M))
if len(_prev_declared) < 2:
    raise SystemExit(f"直前の版の宣言を {len(_prev_declared)} 件しか読めなかった = 読み口が死んでいる")

_demoted = sorted(_prev_declared & set(NOT_A_CONTRACT))
if _demoted:
    raise SystemExit(
        "★契約から格下げされた定数がある★ "
        "(直前の版では DECLARED に在り、今は NOT_A_CONTRACT に在る):\n  "
        + "\n  ".join(_demoted)
        + "\n  ⇒ 守られていた物の守りを外す一手である。黙って通さない。"
          "\n  ⇒ 本当に契約でないなら、何故 前の版で契約だったのかを稿へ書き、"
          "家老の裁を経てから移せ")

undeclared = sorted(set(found) - declared - set(NOT_A_CONTRACT))
if undeclared:
    raise SystemExit(
        "契約として宣言されていない数値の定数がある "
        "(値を動かしても、どの試験も赤くならない状態である):\n  "
        + "\n  ".join(f"{n} = {found[n]}" for n in undeclared)
        + "\n  ⇒ 契約なら T-014 の DECLARED へ足せ。"
          " 契約でないなら T-015 の NOT_A_CONTRACT へ理由つきで足せ")

print(f"OK every constant is accounted for: 本体 {len(found)} 件 / "
      f"宣言 {len(declared)} 件 / 契約でないと明示 {len(NOT_A_CONTRACT)} 件")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK every constant is accounted for"
}
