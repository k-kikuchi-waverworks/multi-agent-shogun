#!/usr/bin/env bats
# test_idle_revive_status_normalize.bats — status 注記正規化 + eligible 観測性の変異試験.
#
# ★なぜこの試験が在るか (2026-07-26 朝の実害)★:
#   家老の帳簿慣行 `status: 'assigned   # 2026-07-26 07:23 家老dispatch=…'` は YAML 上
#   引用符内の【一つの文字列】であり、ACTIVE_STATUSES との完全一致照合に落ちる。
#   その結果 07:28-08:31 の枠切れで assigned 4体が存在するのに scan の目には
#   active task = 0 — 個別stall・quorum停電型・家老degrade・上流障害台帳・R1/R2 の
#   ★全経路が入口で消灯★し、番人 (cmd_1355/1356 の仕掛け) は一度も呼ばれなんだ。
#   「誤clearゼロ」は番人の手柄ではなく盲目の副作用であった。
#   log 側の顔 = 「対象なし」行 82 連続に分母が印字されず、eligible=0 (何も見えて
#   おらぬ) と 全員健全 の区別がつかなんだ — ★分母0の検知層は全PASSと区別がつかぬ★。
#
# 契約 (idle_revive_scan.py normalize_status + scan() eligible 返却):
#   T-STA-001: 注記付き 'assigned   # …' の idle 固着が★見える★ (revive 候補になる)
#   T-STA-002: 注記付き 'done   # …' は active に化けぬ (正規化が偽 active を作らぬ)
#   T-STA-003: 「対象なし」行に eligible=N が印字される (busy でも分母に数える)
#   T-STA-004: report 側の注記付き 'completed   # …' も完了と読める (帳簿漏れ型を
#              stall_watchdog 領分へ残す既存契約が注記で破れぬ)
#   T-STA-005: 'assigned:' 型の書き癖 drift でも読める (T-SWD-004 の兄側移植 =
#              軍師二号 OBS-3: 変異 M-G1「句読点耐性だけ折る」が兄では 4/4 緑のまま
#              生き残った = 上乗せ防御が一本の test にも守られておらなんだ穴)
#   T-STA-006: '★assigned★家老dispatch★' (空白を挟まぬ ★ 密着) でも見える (軍師二号
#              OBS-2: 家老は ★ を常用ゆえ、空白を挟まぬ日に盲目が戻る現実の的)
#   T-STA-007: OBS-2 の読めぬ 9 形すべて + 乗っ取り耐性の直接契約 (normalize_status
#              を module 直呼びで全形一括検分 — scan 経由 1 形ずつでは 9 形の網羅が重い)
#
# 変異登録 (config/mutation_registry.yaml): MUT-1154-001 (正規化を折る→T-STA-001 赤) /
# MUT-1154-002 (eligible 印字を折る→T-STA-003 赤) /
# MUT-1154-003 (allowlist 抽出を旧 blocklist 形へ退行→T-STA-006 赤)。
# 本番 agent には触れない: fixture roster (ashigaru91-92 = 実在しない agent 名) +
# pane-state-file 注入 + IDLE_REVIVE_INBOX_WRITE stub + probe monkeypatch で完全隔離
# (test_idle_revive_quorum.bats と同型ハーネス)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_PY="$PROJECT_ROOT/scripts/idle_revive_scan.py"
    export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_sta.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/state"

    export INBOX_STUB_RECORD="$TEST_TMPDIR/inbox_record.txt"
    cat > "$TEST_TMPDIR/inbox_stub.sh" <<'STUB'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$1" "$3" "$4" "$2" >> "$INBOX_STUB_RECORD"
exit 0
STUB
    chmod +x "$TEST_TMPDIR/inbox_stub.sh"
    export IDLE_REVIVE_INBOX_WRITE="$TEST_TMPDIR/inbox_stub.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fixture agent: status 文字列を引数で受ける (注記付き実慣行をそのまま書ける)。
# mtime 2h 前 = stall 閾値 (15分) 確実超過。
_write_task_status() {
    local agent="$1" status="$2"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: subtask_sta_${agent}
  parent_cmd: cmd_test
  assigned_to: ${agent}
  status: '${status}'
EOF
    touch -d '2 hours ago' "$Q/tasks/${agent}.yaml"
}

_write_pane_states() {
    : > "$TEST_TMPDIR/pane_state.yaml"
    local pair
    for pair in "$@"; do
        echo "${pair%%:*}: ${pair##*:}" >> "$TEST_TMPDIR/pane_state.yaml"
    done
}

# python harness: probe/pane本文 monkeypatch つき非 dry-run 実行
# (test_idle_revive_quorum.bats の _run_main_py と同型)。
_run_main_py() {
    "$VENV_PY" - "$@" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
irs.probe_agent_state = lambda agent: os.environ.get("FAKE_PROBE_STATE", "idle")
irs.pane_upstream_text = lambda agent: os.environ.get("FAKE_PANE_TEXT", "")
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        "--stall-min", "15"] + sys.argv[1:]
rc = irs.main(argv)
print(f"MAIN_RC={rc}")
PY
}

# ---------------------------------------------------------------------------
# T-STA-001: 注記付き assigned の idle 固着が【見える】= revive 候補になる。
# これが落ちる形 = 2026-07-26 朝の盲目 (assigned 存在下で active=0) の再来。
# ---------------------------------------------------------------------------
@test "T-STA-001: annotated 'assigned   # note' task IS visible — idle-stuck agent becomes revive candidate (mutation proof: MUT-1154-001)" {
    _write_task_status ashigaru91 "assigned   # 2026-07-26 07:23 家老dispatch=検知層の検分を任せる"
    _write_pane_states ashigaru91:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "MAIN_RC=0"
    # 正規化が効いた証拠 = 複合 AND 成立の revive が名指しで出る
    echo "$output" | grep -q "ACTION=revive AGENT=ashigaru91"
    echo "$output" | grep -q "status=assigned未完"
    # 実発行まで到達 (clear_command が stub に1通)
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-STA-002: 注記付き done は active に化けぬ (正規化が偽 active を作らぬ側の契約)。
# ---------------------------------------------------------------------------
@test "T-STA-002: annotated 'done   # note' task does NOT become active — no clear, eligible=0" {
    _write_task_status ashigaru91 "done   # 2026-07-26 07:45 完遂 = 台帳登録 (詳細は report)"
    _write_pane_states ashigaru91:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "revive 対象なし"
    echo "$output" | grep -q "eligible=0"
    [ ! -f "$INBOX_STUB_RECORD" ]
}

# ---------------------------------------------------------------------------
# T-STA-003: 「対象なし」行に分母 (eligible=N) が印字される。busy の注記付き
# assigned 2体 → 対象なしだが eligible=2。この行が eligible 無しに戻れば、
# 「82 scan 連続対象なし」が盲目か健全か再び区別できなくなる。
# ---------------------------------------------------------------------------
@test "T-STA-003: '対象なし' line carries eligible=N denominator (busy annotated-assigned agents counted) (mutation proof: MUT-1154-002)" {
    _write_task_status ashigaru91 "assigned   # 2026-07-26 08:00 家老dispatch=実装"
    _write_task_status ashigaru92 "in_progress   # 2026-07-26 08:05 着手済"
    _write_pane_states ashigaru91:busy ashigaru92:busy

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "revive 対象なし"
    echo "$output" | grep -q "eligible=2"
    [ ! -f "$INBOX_STUB_RECORD" ]
}

# ---------------------------------------------------------------------------
# T-STA-004: report 側の注記付き completed も完了と読める = 帳簿漏れ型
# (task=assigned だが report=完了済) は従来どおり stall_watchdog 領分へ除外され、
# 誤 clear を撃たぬ。report 正規化が折れると本 test の agent が誤って候補化する。
# ---------------------------------------------------------------------------
@test "T-STA-004: annotated 'completed   # note' in report still exempts the agent (no false revive)" {
    _write_task_status ashigaru91 "assigned"
    cat > "$Q/reports/ashigaru91_report.yaml" <<'EOF'
report:
  task_id: subtask_sta_ashigaru91
  agent: ashigaru91
  status: 'completed   # 2026-07-26 注記付き完遂の慣行'
  timestamp: '2026-07-26T00:00:00'
EOF
    touch -d '2 hours ago' "$Q/tasks/ashigaru91.yaml" "$Q/reports/ashigaru91_report.yaml"
    _write_pane_states ashigaru91:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "revive 対象なし"
    echo "$output" | grep -q "eligible=0"
    [ ! -f "$INBOX_STUB_RECORD" ]
}

# ---------------------------------------------------------------------------
# T-STA-005: 'assigned:' 型 (末尾句読点 drift) でも見える。弟分 T-SWD-004 の兄側移植。
# ★なぜ今まで無かったか (軍師二号 OBS-3)★: 変異 M-G1「句読点耐性【だけ】を折る」を
# 兄へ撃つと T-STA-001〜004 が 4/4 緑のまま生き残った = 「上乗せの防御」と誇った
# 当の箇所が一本の test にも守られておらなんだ。弟には T-SWD-004 が在った — 兄へ
# 戻すだけでよい、という名指しへの直接回答。
# ---------------------------------------------------------------------------
@test "T-STA-005: trailing-colon 'assigned:' drift is still readable — revive candidate (OBS-3 backport of T-SWD-004)" {
    _write_task_status ashigaru91 "assigned:"
    _write_pane_states ashigaru91:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ACTION=revive AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-STA-006: '★assigned★家老dispatch★' (空白を挟まぬ ★ 密着) でも見える。
# 軍師二号 OBS-2 の筆頭形: 家老は ★ を常用ゆえ「空白を挟まぬ日」は現実に来る。
# 旧実装 (空白 split + :;,. rstrip) はこの形で盲目に戻る = blocklist の宿命。
# これが落ちる形 = allowlist 抽出の退行 (MUT-1154-003 の的)。
# ---------------------------------------------------------------------------
@test "T-STA-006: star-adjacent '★assigned★note★' (no whitespace) IS visible — revive candidate (mutation proof: MUT-1154-003)" {
    _write_task_status ashigaru91 "★assigned★家老dispatch=検知層の検分★"
    _write_pane_states ashigaru91:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ACTION=revive AGENT=ashigaru91"
    echo "$output" | grep -q "status=assigned未完"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-STA-007: OBS-2 の読めぬ 9 形すべての直接契約 + 乗っ取り耐性 (負例)。
# scan 経由で 9 形を 1 本ずつ回すのは重いため normalize_status を直呼びで一括検分。
# 負例 = 注記中の状態語に乗っ取られぬ (先に現れた語が勝つ) / 非文字列は素通し /
# ASCII 語ゼロは "" (不可視のまま)。
# ---------------------------------------------------------------------------
@test "T-STA-007: all 9 OBS-2 decorated forms normalize to 'assigned'; note words cannot hijack" {
    run "$VENV_PY" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
n = irs.normalize_status
# OBS-2 の 9 形 (軍師二号実測: ★密着・全角括弧/句読点・…・—・/ で盲目が戻る)
forms = [
    "★assigned★家老dispatch=検知層の検分★",   # 1 ★密着 (空白なし)
    "assigned（2026-07-26 07:23 家老dispatch）",  # 2 全角括弧密着
    "【assigned】家老dispatch",                   # 3 全角隅付き括弧
    "assigned。手番待ち",                          # 4 全角句点密着
    "assigned、検証中",                            # 5 全角読点密着
    "assigned：注記",                              # 6 全角コロン密着
    "assigned…注記",                               # 7 三点リーダ密着
    "assigned—注記",                               # 8 em-dash 密着
    "assigned/注記",                               # 9 スラッシュ密着
]
ng = []
for f in forms:
    got = n(f)
    if got != "assigned":
        ng.append(f"形 {f!r} → {got!r} (expected 'assigned')")
# 乗っ取り耐性: 注記中の 'assigned' が done を active に化けさせぬ (先勝ち契約)
for f, want in [
    ("done   # 家老dispatch=assigned直後に完遂", "done"),
    ("★done★assigned待ちの注記★", "done"),
    ("2026-07-26 assigned", "assigned"),  # 日付先行でも状態語へ届く (数字 run は語でない)
    ("完了", ""),                          # ASCII 語ゼロ → 不可視のまま
]:
    got = n(f)
    if got != want:
        ng.append(f"負例 {f!r} → {got!r} (expected {want!r})")
if n(None) is not None:
    ng.append("非文字列 None が素通しされぬ")
if ng:
    print("\n".join(ng))
    raise SystemExit(1)
print("ALL_9_FORMS_OK")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ALL_9_FORMS_OK"
}
