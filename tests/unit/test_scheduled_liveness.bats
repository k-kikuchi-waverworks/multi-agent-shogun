#!/usr/bin/env bats
# test_scheduled_liveness.bats — cmd_1465:
# 定時実行 (JOBS) の「終わった証」を検める仕掛け (scripts/scheduled_liveness_check.py) と、
# それを 15 分毎の監視スクリプトへ相乗りさせた配線を縛る。
#
# ■ なぜ必要か
#   毎朝のチェックは、全部の段が終わった後で、非 PASS の時だけ家老へ知らせます。
#   そのため「全部 緑で終わった」と「途中で死んだ」が、どちらも 0 通で同じ顔になります。
#   同じ形が定時実行 7 本のうち 5 本にあり、AituberDvcGc は現に 73 日 止まったまま
#   誰も気づいていませんでした。
#
# ■ 2026-07-28 の丙で足した分
#   証を持たなかった 3 本 (idle_revive_scan / stall_watchdog_scan / queue_backup) に、
#   走り畢えた刻を 1 行 書かせました。書くのは「最後まで来た時だけ」で、途中で死ねば
#   出ません。ここでは書く側 (T-SL-019〜022) と読む側の両方を縛ります。
#   ★母数は 7 → 8 へ動きました★ (8 本目 = queue の控え・cmd_1466)。
#   ゆえに ★この suite に焼いてある本数は 7 ではなく 8 です★。前の数と突き合わせる者へ。
#
# ■ 本数を試験に焼いてある理由 (家老 2026-07-28 13:34 の裁)
#   註は黙って古くなりますが、試験は JOBS が変われば現に赤くなり、人に見させます。
#   ★JOBS を増やして此処が赤くなるのは、壊れたのではなく報せです。★
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

# 8 本すべてに新しい「終わった証」を置く。
# 丙 (2026-07-28) より前は、うち 2 本が終わりの印を持たない作りで、ここでは作れなかった。
# 今は 3 本 (idle_revive_scan / stall_watchdog_scan / queue_backup) が証を書くので、
# 8 本すべてを揃えられる。★揃えられること自体が、丙で塞いだ穴の姿である。★
_fresh_all() {
    echo "── [gate_nightly] 終了 gate-1=PASS  ($NOW)" > "$L/gate_nightly.log"
    echo "[$NOW] OK — http=200" > "$L/engine_devserver_morning_check.log"
    : > "$L/pf_account_rename_reminder.log"
    echo "$NOW" > "$L/last_backup_f_to_d.txt"
    echo "$NOW" > "$L/last_dvc_gc_mirror.txt"
    echo "$NOW idle_revive_scan 終了 rc=0" > "$L/last_idle_revive_scan_end.txt"
    echo "$NOW stall_watchdog_scan 終了 rc=0" > "$L/last_stall_watchdog_scan_end.txt"
    echo "$NOW queue_backup 終了" > "$L/last_queue_backup_end.txt"
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

@test "T-SL-001: 証を持つ 8 本が新しければ、1 本も鳴らない" {
    _fresh_all
    _liveness
    [ "$(_verdict_of gate_nightly)" = "OK" ]
    [ "$(_verdict_of engine_devserver_morning_check)" = "OK" ]
    [ "$(_verdict_of pf_account_rename_reminder)" = "OK" ]
    [ "$(_verdict_of AituberFBackupToD)" = "OK" ]
    [ "$(_verdict_of AituberDvcGc)" = "OK" ]
    [ "$(_verdict_of idle_revive_scan)" = "OK" ]
    [ "$(_verdict_of stall_watchdog_scan)" = "OK" ]
    [ "$(_verdict_of queue_backup)" = "OK" ]
    # 丙より前は、ここで 2 本が「証を持たない」側に残っていた。今は 0 本である。
    echo "$output" | grep -q "STALE=0 MISSING=0"
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
    # 終わりの証だけを消し、log は今この瞬間の更新時刻で置く。
    # = 「走った証」はあるが「終わった証」は無い状態。ここで OK と出れば、
    #   更新時刻を証の代わりに使っている証拠になる。
    rm -f "$L/last_idle_revive_scan_end.txt"
    echo "[idle_revive] ===== scan $NOW =====" > "$L/idle_revive_scan.log"
    _liveness
    [ "$(_verdict_of idle_revive_scan)" = "MISSING" ]
}

# ── (う) 配線を現に通る (部品でなく監視スクリプト本体を撃つ) ─────────────

@test "T-SL-007: 監視スクリプトを撃つと、8 本の所見と母数が現に出る" {
    _fresh_all
    _watchdog
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 8 ]
    echo "$output" | grep -q "定時実行の見張り (cmd_1465) 母数=8本"
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
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 8 ]
}

@test "T-SL-011: 本番の logs/ に対しても 8 本ぶん現に届く (読むだけ・書き込み 0)" {
    # fixture だけで緑になり、本番の置き場には一度も届いていない、という形を防ぐ。
    # 判定の中身は問わない (現物は日々 動くため。条B = 数を釘付けにしない)。
    run python3 "$LIVENESS"
    [ "$(echo "$output" | grep -c '^SL_JOB=')" -eq 8 ]
    echo "$output" | grep -q "母数=8本"
}

# ── 並べ方 (encoding) を見る側 ────────────────────────────────────
# 2026-07-28 に四号と軍師二号が現物で示した形を縛ります。
#   UTF-16 を utf-8 として読んでも、改行の \n が 1 バイト残るので行は刻まれます。
#   ゆえに「1 行でも読めたか」を見る canary は、UTF-16 のファイルで現に緑になります。
#   見るべきは行数ではなく、並べ方そのものです。
# 何ゆえこの suite に要るか = 成功の記録を書くのは Windows の PowerShell で、
#   読むのは WSL の python です。書く側と読む側が別の道具ゆえ、現に起こりえます。

@test "T-SL-014: UTF-16 で書かれた成功の記録でも、日時として読める" {
    _fresh_all
    python3 -c "
import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes((sys.argv[2]+'\n').encode('utf-16'))
" "$L/last_dvc_gc_mirror.txt" "$NOW"
    _liveness
    [ "$(_verdict_of AituberDvcGc)" = "OK" ]
}

@test "T-SL-015: BOM の無い UTF-16 でも読める (判じる手掛かりが NUL だけの形)" {
    _fresh_all
    python3 -c "
import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes((sys.argv[2]+'\n').encode('utf-16-le'))
" "$L/last_dvc_gc_mirror.txt" "$NOW"
    _liveness
    [ "$(_verdict_of AituberDvcGc)" = "OK" ]
}

@test "T-SL-016: 読めない時は、並べ方を名乗る (直す先が別ゆえ)" {
    _fresh_all
    # 日時が 1 つも書かれていない記録。読めないこと自体は正しい。
    echo "no timestamp here" > "$L/last_dvc_gc_mirror.txt"
    _liveness
    [ "$(_verdict_of AituberDvcGc)" = "MISSING" ]
    echo "$output" | grep -q "並べ方="
}

@test "T-SL-017: canary は行数でなく並べ方の内訳を刷る" {
    _fresh_all
    python3 -c "
import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes(b'x\n'.decode().encode('utf-16'))
" "$L/last_dvc_gc_mirror.txt"
    run python3 "$LIVENESS" --canary --logs-dir "$L"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "enc=utf-16"
    echo "$output" | grep -q "内訳="
}

@test "T-SL-018: canary は、並べ方を判じる口が現に生きているかを己で撃つ" {
    _fresh_all
    run python3 "$LIVENESS" --canary --logs-dir "$L"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "判じる口=生きています"
}

# ── 証を書く側 (cmd_1465 の丙・2026-07-28) ────────────────────────────
# 読む側だけを縛ると、書く側が黙って止まった日に気づけない。
# ここは ★書き手の script そのものを撃ち、証が現に出るか★ を見る。
# 途中で殺した時に出ないことは、時計を測って撃つ要が在るので
# plans/cmd_1465_liveness_proof_mutants.sh の側に置いてある (窓の中で殺せたかを数で刷る)。

@test "T-SL-019: 監視スクリプトが走り畢えると、終わりの証を現に書く" {
    S="$(mktemp -d)"
    run python3 "$SCAN" --dry-run --queue-root "$Q" --liveness-logs-dir "$L" --stamp-dir "$S"
    [ "$status" -eq 0 ]
    # 「何か出たか」でなく「此の名の証が此処に出たか」で見る
    [ -s "$S/last_stall_watchdog_scan_end.txt" ]
    grep -q "stall_watchdog_scan 終了" "$S/last_stall_watchdog_scan_end.txt"
    rm -rf "$S"
}

@test "T-SL-020: 番人 (idle_revive_scan) が走り畢えると、終わりの証を現に書く" {
    S="$(mktemp -d)"
    echo '{}' > "$Q/panes.json"
    run python3 "$STALL_SCAN_ROOT/scripts/idle_revive_scan.py" --dry-run \
        --queue-root "$Q" --stamp-dir "$S" --pane-state-file "$Q/panes.json"
    [ "$status" -eq 0 ]
    [ -s "$S/last_idle_revive_scan_end.txt" ]
    grep -q "idle_revive_scan 終了" "$S/last_idle_revive_scan_end.txt"
    rm -rf "$S"
}

@test "T-SL-021: queue の控えが走り畢えると、終わりの証を現に書く" {
    S="$(mktemp -d)"; B="$(mktemp -d)"
    # env を明に噛ませる。bats の run の前へ置く書き方だと、渡ったかどうかが
    # 出力から読めず、渡っていなくても控えは出来てしまう (本番の置き場が汚れる)。
    run env QUEUE_BACKUP_DIR="$B" QUEUE_STAMP_DIR="$S" \
        bash "$STALL_SCAN_ROOT/scripts/queue_backup.sh"
    [ "$status" -eq 0 ]
    # 控えが差し替えた置き場へ現に出来たこと (= env が渡った証)
    [ -n "$(ls "$B"/queue_*.tar.gz 2>/dev/null)" ]
    [ -s "$S/last_queue_backup_end.txt" ]
    grep -q "queue_backup 終了" "$S/last_queue_backup_end.txt"
    rm -rf "$S" "$B"
}

@test "T-SL-022: 試験の走行は、本番の logs/ へ証を 1 バイトも書かない (条C)" {
    # 己の作り物が本番の数を動かさぬこと。--stamp-dir を渡さず --queue-root だけ渡す形。
    before="$(ls -la "$REPO/logs/last_stall_watchdog_scan_end.txt" 2>/dev/null || echo none)"
    run python3 "$SCAN" --dry-run --queue-root "$Q" --liveness-logs-dir "$L"
    [ "$status" -eq 0 ]
    after="$(ls -la "$REPO/logs/last_stall_watchdog_scan_end.txt" 2>/dev/null || echo none)"
    [ "$before" = "$after" ]
}

@test "T-SL-023: 書く側と読む側が、同じ名前の付け方を通っている" {
    # 名前の付け方が二箇所に分かれると、片方だけ直った日に読む側が黙って
    # 「証が無い」と答える。それは「走らなかった」と同じ顔で返る。
    run python3 -c "
import sys; sys.path.insert(0, '$STALL_SCAN_ROOT/scripts')
import scheduled_liveness_check as l
names = [j['name'] for j in l.JOBS if j.get('stamp')]
for n in ('idle_revive_scan', 'stall_watchdog_scan', 'queue_backup'):
    j = [x for x in l.JOBS if x['name'] == n][0]
    assert j['stamp'] == l.stamp_filename(n), (n, j['stamp'], l.stamp_filename(n))
print('ok', len(names))
"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ok "
}
