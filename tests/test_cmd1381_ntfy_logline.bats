#!/usr/bin/env bats
# cmd_1381 段5(a)(b) — ★ntfy 送信 log を【機械が読める1行】に保つ牙★ (2026-07-27 足軽四号)
#
# ★偽 curl の流儀★= 本 script は ★一度も ntfy.sh へ本物の矢を放たぬ★ (殿は御就寝ゆえ)。
#   PATH の先頭へ偽 curl を差し、FAKE_CURL_MODE で ★届く/非2xx/curl が死ぬ★ を作り分ける。
# ★本物の log を汚さぬ★= NTFY_LOG_FILE (段5(a) で開けた試験の口) で temp へ逃がす。
#   ★T9 が【汚しておらぬこと】を md5 で毎回 実測する★ = 約束を言葉でなく数で残す。

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  export NTFY_LOG_FILE="$TMP/ntfy_send.log"
  REAL_LOG="$REPO/logs/ntfy_send.log"
  REAL_MD5_BEFORE="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# ★偽 curl★= -w "%{http_code}" の位置に印字される物だけを真似る (本物は撃たぬ)
case "${FAKE_CURL_MODE:-ok}" in
  ok)        printf '200'; exit 0 ;;
  http500)   printf '500'; exit 0 ;;
  die)       exit 7 ;;                 # ★何も印字せず非0★ = 段4 が塞いだ B の形
  die_000)   printf '000'; exit 6 ;;   # 印字はするが非0
esac
FAKE
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  # ★本物の log を汚しておらぬことを毎回 確かめる★ (約束は数で残す)
  local after
  after="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"
  [ "$REAL_MD5_BEFORE" = "$after" ] || {
    echo "★本物の log が変わっておる★ before=$REAL_MD5_BEFORE after=$after" >&2
    return 1
  }
  rm -rf "$TMP"
}

# ── (a) 形の検 ────────────────────────────────────────────────────────────

@test "A1 成功行に curl_rc が在り、時刻に offset が付く (場が固定)" {
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "試験 A1"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]
  # cmd_1419 で caller= と fp= が curl_rc と title の間に入った（title は常に最後）。
  run grep -cE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\+[0-9]{2}:[0-9]{2}\] HTTP=200 curl_rc=0 caller=\S+ fp=\S+ title=' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "A2 ★title に改行が在っても 1 行のまま★ (1行1事象を構造で保つ)" {
  # ★旧版なら此処で行が割れた★ = 読み手は 1 事象を 2 事象と数える
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "$(printf '一行目\n二行目\n三行目')"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]
  run grep -c '二行目' "$NTFY_LOG_FILE"   # ★消しておらぬ = 同じ行に居る★
  [ "$output" = "1" ]
}

@test "A3 ★80 byte の境で多byteを切っても、行は妥当な UTF-8★" {
  # ★本物の log には此の傷が 46 箇所 現に在る★ (段5(a) 以前の head -c 80 の跡)
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "$(python3 -c 'print("あ"*60)')"
  [ "$status" -eq 0 ]
  run python3 -c "import sys;open(sys.argv[1],encoding='utf-8').read();print('valid')" "$NTFY_LOG_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
}

@test "A4 制御文字 (TAB/CR) も落ちる" {
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "$(printf 'a\tb\rc')"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]
  run grep -cP '[\x00-\x1f\x7f]' "$NTFY_LOG_FILE"
  [ "$output" = "0" ]
}

@test "A5 curl が死んでも 1 行残り、curl_rc に其の値が載る (段4 の B を保つ)" {
  FAKE_CURL_MODE=die run bash "$REPO/scripts/ntfy.sh" "試験 A5"
  [ "$status" -eq 7 ]                    # ★呼び手から見た rc は従前どおり★
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]
  run grep -c 'HTTP=NONE curl_rc=7 ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "A6 非 2xx は HTTP に載り curl_rc=0 のまま (二つの死に方を混ぜぬ)" {
  FAKE_CURL_MODE=http500 run bash "$REPO/scripts/ntfy.sh" "試験 A6"
  [ "$status" -eq 1 ]
  run grep -c 'HTTP=500 curl_rc=0 ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "A7 ★旧 1,097 行が今も解ける★ (形を変えたが過去を読めなくしておらぬ)" {
  run python3 - "$REPO/logs/ntfy_send.log" <<'PY'
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent.parent / "scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "g", Path(sys.argv[1]).parent.parent / "scripts" / "gate_ntfy_sendlog.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
text = Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace")
ev, unparsed, total = g.parse_lines(text, None)
print(f"{len(ev)}/{total} unparsed={unparsed}")
sys.exit(0 if unparsed == 0 and total > 1000 else 1)
PY
  [ "$status" -eq 0 ]
}

# ── (a)→(b) 繋いだ検 = ★偽 log でなく【偽 curl が現に書いた log】を判定子に食わせる★ ──

@test "B1 ★鳴らぬ★: 現に届いた log を判定子は PASS と読む" {
  FAKE_CURL_MODE=ok bash "$REPO/scripts/ntfy.sh" "試験 B1" >/dev/null
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[NTFY-SEND-OK]"* ]]
}

@test "B2 ★鳴る★: curl が死んだ log を判定子は FAIL と読む" {
  FAKE_CURL_MODE=die bash "$REPO/scripts/ntfy.sh" "試験 B2" >/dev/null || true
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[NTFY-SEND-DEAD]"* ]]
  [[ "$output" == *"繋がらぬ"* ]]
}

@test "B3 ★鳴る★: 非2xx だけの log も FAIL" {
  FAKE_CURL_MODE=http500 bash "$REPO/scripts/ntfy.sh" "試験 B3" >/dev/null 2>&1 || true
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[NTFY-SEND-DEAD]"* ]]
}

@test "B4 ★鳴らぬ★: 成功が混じれば FAIL に倒れぬ (常に鳴る門でないことの証)" {
  FAKE_CURL_MODE=http500 bash "$REPO/scripts/ntfy.sh" "試験 B4-1" >/dev/null 2>&1 || true
  FAKE_CURL_MODE=ok      bash "$REPO/scripts/ntfy.sh" "試験 B4-2" >/dev/null
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[NTFY-SEND-OK]"* ]]
}

@test "B5 ★未検分★: 何も撃っておらぬ log は赤でも緑でもない" {
  : > "$NTFY_LOG_FILE"
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[NTFY-SEND-UNSEATED]"* ]]
  [[ "$output" != *"[NTFY-SEND-DEAD]"* ]]
}

@test "B6 判定子の selftest 26 本が緑" {
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --selftest
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 件の NG / 検 26 本"* ]]
}

# ── cmd_1400 = ★試験が本番の記録を汚さぬこと★ を構造で縛る ──────────────────
# ★実害の再演★= test_cmd1363 が偽 curl で ntfy.sh を走らせ、本番 log へ 4 行 書いた。
#   ★書き手の規律 (各試験が NTFY_LOG_FILE を書く) では足りぬ = 忘れることが当の不具合であった★。

@test "C1 ★NTFY_LOG_FILE を書き忘れた試験でも本番 log へ届かぬ★ (既定が tmp へ向く)" {
  unset NTFY_LOG_FILE                      # ★忘れっぽい試験の再現★
  local before after
  before="$(md5sum "$REAL_LOG" | awk '{print $1}')"
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "★C1 忘れっぽい試験★"
  [ "$status" -eq 0 ]
  after="$(md5sum "$REAL_LOG" | awk '{print $1}')"
  [ "$before" = "$after" ]                 # ★本番は 1 byte も動いておらぬ★
  [ -f "$BATS_TEST_TMPDIR/ntfy_send.log" ] # ★而して記録そのものは失われておらぬ (tmp に在る)★
  run grep -c 'HTTP=200 curl_rc=0 ' "$BATS_TEST_TMPDIR/ntfy_send.log"
  [ "$output" = "1" ]
  export NTFY_LOG_FILE="$TMP/ntfy_send.log"
}

@test "C2 ★明示の NTFY_LOG_FILE は guard より優先★ (試験が己で行き先を決める道を塞がぬ)" {
  FAKE_CURL_MODE=ok run bash "$REPO/scripts/ntfy.sh" "★C2 明示★"
  [ "$status" -eq 0 ]
  [ -f "$NTFY_LOG_FILE" ]
  [ ! -f "$BATS_TEST_TMPDIR/ntfy_send.log" ]   # ★tmp の既定へは逃げておらぬ★
}

@test "C3 ★試験行の除外は sha256 照合ゆえ silencer にならぬ★ (1 byte 違えば当たらぬ)" {
  local d="$TMP/c3"; mkdir -p "$d"
  local L="$d/ntfy_send.log"
  local stamp; stamp="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
  printf '[%s] HTTP=500 curl_rc=0 title=試験由来\n' "$stamp" > "$L"
  printf '[%s] HTTP=500 curl_rc=0 title=本物の失敗\n' "$stamp" >> "$L"
  # ★1 行目だけを名指す名簿を作る★
  local h; h="$(head -1 "$L" | tr -d '\n' | sha256sum | awk '{print $1}')"
  printf 'schema: ntfy-send-testlines/1\nlines:\n  - sha256: %s\n' "$h" > "$d/ntfy_send.testlines.yaml"
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$L"
  [ "$status" -eq 1 ]                                  # ★本物の失敗は生き残って鳴る★
  [[ "$output" == *"[NTFY-SEND-DEAD]"* ]]
  [[ "$output" == *"除いた行 1 本"* ]]                  # ★除いた本数を黙らず出す★
}

@test "C4 ★名簿が無ければ何も除かぬ★ (除外は足す側の働き = 既定は安全側)" {
  local d="$TMP/c4"; mkdir -p "$d"
  local L="$d/ntfy_send.log"
  printf '[%s] HTTP=500 curl_rc=0 title=失敗\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" > "$L"
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$L"
  [ "$status" -eq 1 ]
  [[ "$output" != *"除いた行"* ]]
}
