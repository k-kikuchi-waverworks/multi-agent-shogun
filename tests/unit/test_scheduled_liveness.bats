#!/usr/bin/env bats
# test_scheduled_liveness.bats — cmd_1465:
# 定時実行 7 本の「終わった証」を検める仕掛け (scripts/scheduled_liveness_check.py) と、
# それを 15 分毎の監視スクリプトへ相乗りさせた配線を縛る。
#
# ■ なぜ必要か
#   毎朝のチェックは、全部の段が終わった後で、非 PASS の時だけ家老へ知らせます。
#   そのため「全部 緑で終わった」と「途中で死んだ」が、どちらも 0 通で同じ顔になります。
#   同じ形が定時実行 7 本のうち 5 本にあり、AituberDvcGc は現に 73 日 止まったまま
#   誰も気づいていませんでした。
#
# ■ この suite が守る物 (CLAUDE.md 条4 = 陽性と陰性の二つを撃つ)
#   (あ) 鳴るべき時に鳴る       … T-SL-002 / 003 / 004
#   (い) 鳴らないべき時に黙る   … T-SL-001 / 005 / 006
#   (う) 配線を現に通る         … T-SL-007 / 008 / 009
#        判定の部品だけを直接 呼ぶ試験は、判定を呼ぶ配線を試験しません。
#        そこで 007〜009 は監視スクリプト本体を撃ち、その出力を見ます
#        (2026-07-28 に六号が踏んだ「門の判定は試験され、門への配線は試験されていない」形)。
#   (え) canary                 … T-SL-010 / 011
#        「0 件」が本物か、探し方が壊れているだけかを分けます。
#   (お) 己を母数から外す (条C) … 試験は必ず mktemp の logs/ を渡し、本番の logs/ は
#        T-SL-011 で読むだけ (書き込み 0)。試験の作り物が本番の数を動かしません。

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # 変異試験は写しの根を渡して撃つ (他の stall_watchdog 系 suite と同じ作法)。
    STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$REPO}"
    SCAN="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    LIVENESS="$STALL_SCAN_ROOT/scripts/scheduled_liveness_check.py"
    L="$(mktemp -d)"          # 差し替える logs/
    Q="$(mktemp -d)"          # 差し替える queue/ (監視スクリプト本体を撃つ時に要る)
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/inbox"
    echo "commands: []" > "$Q/shogun_to_karo.yaml"
    NOW="$(date '+%Y-%m-%d %H:%M:%S')"
}

teardown() {
    [ -n "${L:-}" ] && rm -rf "$L"
    [ -n "${Q:-}" ] && rm -rf "$Q"
}

# 5 本すべてに新しい「終わった証」を置く。
# 残る 2 本 (idle_revive_scan / stall_watchdog_scan) は、そもそも終わりの印を
# 持たない作りなので、ここでは作れない。それ自体がこの cmd の見つけた穴である。
_fresh_all() {
    echo "── [gate_nightly] 終了 gate-1=PASS  ($NOW)" > "$L/gate_nightly.log"
    echo "[$NOW] OK — http=200" > "$L/engine_devserver_morning_check.log"
    : > "$L/idle_revive_scan.log"
    : > "$L/stall_watchdog_scan.log"
    : > "$L/pf_account_rename_reminder.log"
    echo "$NOW" > "$L/last_backup_f_to_d.txt"
    echo "$NOW" > "$L/last_dvc_gc_mirror.txt"
}

# 部品を直に撃つ。$1 以降は追加の引数。
_liveness() {
    run python3 "$LIVENESS" --logs-dir "$L" "$@"
}

# 監視スクリプト本体を撃つ (配線を通す)。本番の queue/ も logs/ も読まない。
_watchdog() {
    run python3 "$SCAN" --dry-run --queue-root "$Q" --liveness-logs-dir "$L" "$@"
}

# $1=job 名 → その行の判定 (SL_VERDICT) を返す
_verdict_of() {
    echo "$output" | sed -n "s/^SL_JOB=$1 SL_VERDICT=\([A-Z]*\) .*/\1/p" | head -1
}

# ── (い) 鳴らないべき時に黙る ───────────────────────────────────────

@test "T-SL-001: 証を持つ 5 本が新しければ、その 5 本は 1 本も鳴らない" {
    _fresh_all
    _liveness
    [ "$(_verdict_of gate_nightly)" = "OK" ]
    [ "$(_verdict_of engine_devserver_morning_check)" = "OK" ]
    [ "$(_verdict_of pf_account_rename_reminder)" = "OK" ]
    [ "$(_verdict_of AituberFBackupToD)" = "OK" ]
    [ "$(_verdict_of AituberDvcGc)" = "OK" ]
    # 古い物は 0 本。残る 2 本は「証を持たない」側であって「古い」側ではない。
    echo "$output" | grep -q "STALE=0"
}

@test "T-SL-005: 古くても、自分で見送りを名乗っていれば鳴らない" {
    _fresh_all
    {
        echo "── [gate_nightly] 終了 gate-1=PASS  (2026-05-01 06:30:00)"
        echo "[gate_nightly] 見送り (前の走行がまだ続いている)"
    } > "$L/gate_nightly.log"
    _liveness
    [ "$(_verdict_of gate_nightly)" = "SKIPPED" ]
}

@test "T-SL-006: 期日前の 1 度きりの物は、走っていなくても鳴らない" {
    _fresh_all
    _liveness --now "2026-07-28T12:00:00"
    [ "$(_verdict_of pf_account_rename_reminder)" = "OK" ]
    echo "$output" | grep -q "SL_JOB=pf_account_rename_reminder.*期日"
}

# ── (あ) 鳴るべき時に鳴る ───────────────────────────────────────────

@test "T-SL-002: 終わった証が古ければ STALE として鳴る" {
    _fresh_all
    echo "2026-05-15 21:17:11" > "$L/last_dvc_gc_mirror.txt"
    _liveness
    [ "$(_verdict_of AituberDvcGc)" = "STALE" ]
    [ "$status" -eq 1 ]
}

@test "T-SL-003: 走ってはいるが終わりの印が 1 本も無ければ MISSING として鳴る" {
    _fresh_all
    # 開始の行だけがある形 = 途中で死んだ時に現に残る姿。
    echo "── [gate_nightly] 開始 ($NOW)" > "$L/gate_nightly.log"
    _liveness
    [ "$(_verdict_of gate_nightly)" = "MISSING" ]
    [ "$status" -eq 1 ]
}

@test "T-SL-004: 成功の記録そのものが無ければ MISSING として鳴る" {
    _fresh_all
    rm -f "$L/last_backup_f_to_d.txt"
    _liveness
    [ "$(_verdict_of AituberFBackupToD)" = "MISSING" ]
    [ "$status" -eq 1 ]
}

@test "T-SL-012: Windows 側が付ける BOM と CR があっても日時を読める" {
    _fresh_all
    printf '\xef\xbb\xbf%s\r\n' "$NOW" > "$L/last_dvc_gc_mirror.txt"
    _liveness
    [ "$(_verdict_of AituberDvcGc)" = "OK" ]
}

@test "T-SL-013: log の更新時刻を「終わった証」の代わりに使わない" {
    _fresh_all
    # 中身は開始の行だけ。更新時刻は今この瞬間 = 「走った証」はあるが「終わった証」は無い。
    echo "[idle_revive] ===== scan $NOW =====" > "$L/idle_revive_scan.log"
    _liveness
    [ "$(_verdict_of idle_revive_scan)" = "MISSING" ]
}

# ── (う) 配線を現に通る (部品でなく監視スクリプト本体を撃つ) ─────────────

@test "T-SL-007: 監視スクリプトを撃つと、7 本の所見と母数が現に出る" {
    _fresh_all
    _watchdog
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 7 ]
    echo "$output" | grep -q "定時実行の見張り (cmd_1465) 母数=7本"
    # 塞げていない範囲を、緑と同じ大きさで名乗っているか (条G)。
    echo "$output" | grep -q "そこは塞げていない"
}

@test "T-SL-008: 監視スクリプトの側でも、古い 1 本が現に STALE として出る" {
    _fresh_all
    echo "2026-05-15 21:17:11" > "$L/last_dvc_gc_mirror.txt"
    _watchdog
    [ "$(_verdict_of AituberDvcGc)" = "STALE" ]
    echo "$output" | grep -q "STALE=1"
}

@test "T-SL-009: --no-liveness-scan を渡せば、この見張りは 1 行も出さない" {
    _fresh_all
    _watchdog --no-liveness-scan
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 0 ]
    # 他の検めまで黙っていないこと (口を閉じたのはこの見張りだけである証)。
    echo "$output" | grep -q "\[stall_watchdog\]"
}

# ── (え) canary ─────────────────────────────────────────────────────

@test "T-SL-010: 判定の綴りが現に出ることを、既知の物で確かめる" {
    _fresh_all
    _liveness
    # 「STALE が 0 本」を、STALE という綴りが出ない状態と取り違えないための対照。
    # 同じ走行で、判定の 4 つの綴りが集計行に必ず並ぶ。
    echo "$output" | grep -q "OK=.*STALE=.*MISSING=.*SKIPPED="
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 7 ]
}

@test "T-SL-011: 本番の logs/ に対しても 7 本ぶん現に届く (読むだけ・書き込み 0)" {
    # fixture だけで緑になり、本番の置き場には一度も届いていない、という形を防ぐ。
    # 判定の中身は問わない (現物は日々 動くため。条B = 数を釘付けにしない)。
    run python3 "$LIVENESS"
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 7 ]
    echo "$output" | grep -q "母数=7本"
}
