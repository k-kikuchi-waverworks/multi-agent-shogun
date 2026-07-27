#!/usr/bin/env bats
# cmd_1419 — ntfy のログに「誰が撃ったか」と「何を撃ったか」を残す (2026-07-27 足軽四号)
#
# 起きたこと: 14:28:34 と 14:28:42 に同じ題が8秒差で2本 飛び、殿のスマホが2回 鳴った。
#   ntfy.sh に再送の口は無い（curl は1発）。よって呼び手が二度 撃ったことになる。
#   ところが従来のログには送り手も本文も残らず、★誰が撃ったかは永久に分からなかった★。
#
# 本番の ntfy へは1本も送らない。偽 curl を PATH の先頭に置き、本番ログは NTFY_LOG_FILE で逃がす。
# 本番ログを汚していないことは teardown で md5 により毎回 確かめる。

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  export NTFY_LOG_FILE="$TMP/ntfy_send.log"
  REAL_LOG="$REPO/logs/ntfy_send.log"
  REAL_MD5_BEFORE="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '200'; exit 0
FAKE
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
  # tmux の agent id は環境に依らせない（試験が誰の盤で走っても同じ結果になるように）
  unset TMUX_PANE
}

teardown() {
  local after
  after="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"
  [ "$REAL_MD5_BEFORE" = "$after" ] || {
    echo "本番ログが変わっている before=$REAL_MD5_BEFORE after=$after" >&2
    return 1
  }
  rm -rf "$TMP"
}

# ── 呼び手の印 ──────────────────────────────────────────────────────────

@test "K1 ログ行に caller が載る（tmux が無い場でも親プロセスで名乗る）" {
  run bash "$REPO/scripts/ntfy.sh" "K1 呼び手の印"
  [ "$status" -eq 0 ]
  run grep -cE ' caller=[^ ]+ ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
  # 「取れなかった」と「不明な誰か」を混ぜない = ppid: を冠している
  run grep -cE ' caller=ppid:[0-9]+' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "K2 tmux から agent id が取れる場では、その id が載る" {
  # 偽 tmux を置く（本物の tmux に依存させない）
  cat > "$TMP/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf 'ashigaru4\n'
FAKE
  chmod +x "$TMP/bin/tmux"
  TMUX_PANE="%9" run bash "$REPO/scripts/ntfy.sh" "K2 agent id"
  [ "$status" -eq 0 ]
  run grep -c ' caller=ashigaru4 ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "K3 caller に空白や制御文字が混じっても1行1事象が壊れない" {
  cat > "$TMP/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf 'ashi garu\t4\n'
FAKE
  chmod +x "$TMP/bin/tmux"
  TMUX_PANE="%9" run bash "$REPO/scripts/ntfy.sh" "K3 汚れた id"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]
  run grep -c ' caller=ashigaru4 ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

# ── 本文の指紋 ──────────────────────────────────────────────────────────

@test "F1 同じ題と本文なら指紋は一致し、違えば変わる" {
  bash "$REPO/scripts/ntfy.sh" "F1 題" "本文 A" >/dev/null
  bash "$REPO/scripts/ntfy.sh" "F1 題" "本文 A" >/dev/null 2>&1
  bash "$REPO/scripts/ntfy.sh" "F1 題" "本文 B" >/dev/null
  local fps
  fps=$(grep -oE ' fp=[0-9a-f]{8}' "$NTFY_LOG_FILE" | sort -u | wc -l)
  [ "$fps" -eq 2 ]            # A と B の2種
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 3 ]
}

@test "F2 本文そのものはログに書かない（指紋だけ）" {
  bash "$REPO/scripts/ntfy.sh" "F2 題" "これは本文である_秘密の語" >/dev/null
  run grep -c '秘密の語' "$NTFY_LOG_FILE"
  [ "$output" = "0" ]
  run grep -cE ' fp=[0-9a-f]{8} ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

# ── 重複の扱い（抑止せず、印を残して警告する）──────────────────────────

@test "D1 同じ題と本文が窓の内に再来したら dup_age が載り、警告が出る" {
  bash "$REPO/scripts/ntfy.sh" "D1 題" "同じ本文" >/dev/null
  run bash "$REPO/scripts/ntfy.sh" "D1 題" "同じ本文"
  [ "$status" -eq 0 ]                       # 送信は止めない
  [[ "$output" == *"警告"* ]]               # 黙って握り潰していない
  run grep -cE ' dup_age=[0-9]+s ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 2 ]   # 2本とも記録に残る
}

@test "D2 窓の外なら重複と見なさない（常に鳴る警告ではない）" {
  bash "$REPO/scripts/ntfy.sh" "D2 題" "同じ本文" >/dev/null
  NTFY_DUP_WINDOW_SEC=0 run bash "$REPO/scripts/ntfy.sh" "D2 題" "同じ本文"
  [ "$status" -eq 0 ]
  run grep -c 'dup_age=' "$NTFY_LOG_FILE"
  [ "$output" = "0" ]
}

@test "D3 題が同じでも本文が違えば重複ではない" {
  bash "$REPO/scripts/ntfy.sh" "D3 題" "本文 A" >/dev/null
  run bash "$REPO/scripts/ntfy.sh" "D3 題" "本文 B"
  [ "$status" -eq 0 ]
  run grep -c 'dup_age=' "$NTFY_LOG_FILE"
  [ "$output" = "0" ]
}

# ── 後方互換 ────────────────────────────────────────────────────────────

@test "R1 旧ログの全行が今も読める（読み手の規則を壊していない）" {
  run python3 - "$REPO" <<'PY'
import importlib.util, pathlib, sys
repo = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("g", repo / "scripts/gate_ntfy_sendlog.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lines = [l for l in (repo / "logs/ntfy_send.log").read_bytes().decode("utf-8", "replace").splitlines() if l.strip()]
bad = [l for l in lines if not m.LINE_RE.match(l)]
print(f"{len(lines)} {len(bad)}")
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
  # 母数を出す = 「0 件で緑」と「読む相手が居らず緑」を分ける
  [ "${output% *}" -gt 1000 ]
}

@test "R2 新しい行も同じ規則で読め、題が空白を含んでも欄が食われない" {
  bash "$REPO/scripts/ntfy.sh" "R2 題 に 空白 が 有る" "本文" >/dev/null
  run python3 - "$REPO" "$NTFY_LOG_FILE" <<'PY'
import importlib.util, pathlib, sys
repo, log = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("g", repo / "scripts/gate_ntfy_sendlog.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
line = log.read_text(encoding="utf-8").splitlines()[0]
g = m.LINE_RE.match(line)
assert g, f"読めない: {line}"
assert g.group("caller"), "caller が空"
assert g.group("fp"), "fp が空"
assert g.group("title") == "R2 題 に 空白 が 有る", g.group("title")
print("ok")
PY
  [ "$status" -eq 0 ]
}

# ── 変異（この試験に牙があるか）────────────────────────────────────────

# 変異用の隔離した木を作る（★共有木は 1 byte も触らない★）。
# 設定は本物を写さず、その場で最小限を書く = 殿の機の設定に依存しない。
make_tree() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/lib" "$dir/config"
  cp "$REPO/scripts/ntfy.sh" "$dir/scripts/"
  cp "$REPO/lib/ntfy_auth.sh" "$dir/lib/"
  printf 'ntfy_topic: "zzz_test_topic_1419"\n' > "$dir/config/settings.yaml"
}

@test "M1 ログから caller を消せば K1/K2 が赤になる" {
  make_tree "$TMP/mut1"
  # まず変異前の写しで緑を確かめる = 「写した木では元々出ない」ではないことを示す
  NTFY_LOG_FILE="$TMP/mut1/before.log" bash "$TMP/mut1/scripts/ntfy.sh" "M1 変異前" >/dev/null
  run grep -c ' caller=' "$TMP/mut1/before.log"
  [ "$output" = "1" ]
  # 変異させる
  sed -i 's/ caller=\$_CALLER//' "$TMP/mut1/scripts/ntfy.sh"
  NTFY_LOG_FILE="$TMP/mut1/after.log" bash "$TMP/mut1/scripts/ntfy.sh" "M1 変異後" >/dev/null
  [ "$(wc -l < "$TMP/mut1/after.log")" -eq 1 ]   # 行は出ている（撃てていないのではない）
  run grep -c ' caller=' "$TMP/mut1/after.log"
  [ "$output" = "0" ]        # caller だけが消える = K1/K2 の主張は現に落ちる
  # 本物は無傷（ログ行の欄と、警告文の中の2箇所に在る）
  run grep -c 'caller=\$_CALLER' "$REPO/scripts/ntfy.sh"
  [ "$output" = "2" ]
}

@test "M2 重複の印を外せば D1 が赤になる" {
  make_tree "$TMP/mut2"
  # 変異前の写しでは印が出る
  NTFY_LOG_FILE="$TMP/mut2/before.log" bash "$TMP/mut2/scripts/ntfy.sh" "M2 題" "同じ本文" >/dev/null
  NTFY_LOG_FILE="$TMP/mut2/before.log" bash "$TMP/mut2/scripts/ntfy.sh" "M2 題" "同じ本文" >/dev/null 2>&1
  run grep -c 'dup_age=' "$TMP/mut2/before.log"
  [ "$output" = "1" ]
  # 変異させる
  sed -i 's/_DUP_FIELD=" dup_age=\${_age}s"/_DUP_FIELD=""/' "$TMP/mut2/scripts/ntfy.sh"
  NTFY_LOG_FILE="$TMP/mut2/after.log" bash "$TMP/mut2/scripts/ntfy.sh" "M2 題" "同じ本文" >/dev/null
  NTFY_LOG_FILE="$TMP/mut2/after.log" bash "$TMP/mut2/scripts/ntfy.sh" "M2 題" "同じ本文" >/dev/null 2>&1
  [ "$(wc -l < "$TMP/mut2/after.log")" -eq 2 ]
  run grep -c 'dup_age=' "$TMP/mut2/after.log"
  [ "$output" = "0" ]        # 印が消える = D1 の主張は現に落ちる
}

# ── その5: 試験の送信が殿の端末を鳴らさない ──────────────────────────────

# 本物の curl が呼ばれたら痕跡が残る偽 curl（呼ばれたこと自体を捕える）
plant_tracer_curl() {
  cat > "$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
echo called >> "$TMP/curl_called"
printf '200'; exit 0
FAKE
  chmod +x "$TMP/bin/curl"
}

@test "S1 bats の中では curl そのものを呼ばない（矢が飛ばない）" {
  plant_tracer_curl
  run bash "$REPO/scripts/ntfy.sh" "S1 試験送信"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/curl_called" ]        # 一度も呼ばれていない
}

@test "S2 送らなかったことと宛先を画面に出す（黙って送らない形にしない）" {
  plant_tracer_curl
  run bash "$REPO/scripts/ntfy.sh" "S2 画面に出す"
  [ "$status" -eq 0 ]
  [[ "$output" == *"送っていない"* ]]
  [[ "$output" == *"https://ntfy.sh/"* ]]   # どこへ送らなかったかが分かる
}

@test "S3 ログにも mode=dryrun として残る（記録からも後で分かる）" {
  plant_tracer_curl
  bash "$REPO/scripts/ntfy.sh" "S3 記録" >/dev/null 2>&1
  run grep -cE ' mode=dryrun ' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
  run grep -c 'HTTP=DRYRUN' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "S4 bats の外でも NTFY_DRY_RUN=1 で止まる（他の枠組み用の逃げ道）" {
  plant_tracer_curl
  run env -u BATS_TEST_FILENAME -u BATS_TEST_TMPDIR -u BATS_RUN_TMPDIR \
      NTFY_DRY_RUN=1 NTFY_LOG_FILE="$TMP/s4.log" bash "$REPO/scripts/ntfy.sh" "S4 明示"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/curl_called" ]
  run grep -c 'HTTP=DRYRUN' "$TMP/s4.log"
  [ "$output" = "1" ]
}

@test "S5 読み手は dryrun の行も読め、成功とも失敗とも数えられる形で残る" {
  plant_tracer_curl
  bash "$REPO/scripts/ntfy.sh" "S5 読み手" >/dev/null 2>&1
  run python3 - "$REPO" "$NTFY_LOG_FILE" <<'PY'
import importlib.util, pathlib, sys
repo, log = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("g", repo / "scripts/gate_ntfy_sendlog.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
line = log.read_text(encoding="utf-8").splitlines()[0]
g = m.LINE_RE.match(line)
assert g, f"読めない: {line}"
assert g.group("mode") == "dryrun", g.groupdict()
assert g.group("http") == "DRYRUN", g.groupdict()
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "M3 試験モードの判定を外せば curl が現に呼ばれる（S1 の主張が落ちる）" {
  make_tree "$TMP/mut3"
  plant_tracer_curl
  # 変異前の写しでは呼ばれない
  NTFY_LOG_FILE="$TMP/mut3/before.log" bash "$TMP/mut3/scripts/ntfy.sh" "M3 変異前" >/dev/null 2>&1
  [ ! -f "$TMP/curl_called" ]
  # 判定を外す（bats の env を見なくする）
  sed -i 's/elif \[ -n "\${BATS_TEST_FILENAME:-}\${BATS_TEST_TMPDIR:-}\${BATS_RUN_TMPDIR:-}" \]; then/elif false; then/' "$TMP/mut3/scripts/ntfy.sh"
  NTFY_LOG_FILE="$TMP/mut3/after.log" bash "$TMP/mut3/scripts/ntfy.sh" "M3 変異後" >/dev/null 2>&1
  [ -f "$TMP/curl_called" ]          # 変異下では現に呼ばれる = S1 は牙を持っている
  run grep -c 'HTTP=200' "$TMP/mut3/after.log"
  [ "$output" = "1" ]
}

@test "S6 逃げ道（NTFY_DRY_RUN=0）を使うと、使ったことが画面に出る（黙っては通らない）" {
  plant_tracer_curl
  NTFY_DRY_RUN=0 run bash "$REPO/scripts/ntfy.sh" "S6 逃げ道"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NTFY_DRY_RUN=0 が明示されている"* ]]
  [ -f "$TMP/curl_called" ]          # 経路は現に通っている（偽 curl ゆえ矢は飛ばない）
}

@test "F3 指紋は欄として読む（題の中に同じ綴りがあっても過去の送信と混同しない）" {
  # 軍師一号 17:51 の名指し: 綴りをログ全文から探すと、題に fp=… を含む行を送信と読む。
  bash "$REPO/scripts/ntfy.sh" "F3 下ごしらえ" "本文" >/dev/null 2>&1
  local fp
  fp=$(grep -oE ' fp=[0-9a-f]{8}' "$NTFY_LOG_FILE" | head -1 | sed 's/ fp=//')
  : > "$NTFY_LOG_FILE"
  # 題の中に指紋の綴りを含む行だけを置く（送信の記録ではない）
  printf '[%s] HTTP=200 curl_rc=0 caller=zzz fp=00000000 title=偽 fp=%s を題に含む行\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$fp" > "$NTFY_LOG_FILE"
  run bash "$REPO/scripts/ntfy.sh" "F3 下ごしらえ" "本文"
  [ "$status" -eq 0 ]
  [[ "$output" != *"警告"* ]]              # 題の中の綴りを過去の送信と読んでいない
  run grep -c 'dup_age=' "$NTFY_LOG_FILE"
  [ "$output" = "0" ]
}

@test "F4 欄として置かれた過去の送信はちゃんと拾う（F3 が牙を鈍らせていないこと）" {
  bash "$REPO/scripts/ntfy.sh" "F4 題" "本文" >/dev/null 2>&1
  run bash "$REPO/scripts/ntfy.sh" "F4 題" "本文"
  [ "$status" -eq 0 ]
  [[ "$output" == *"警告"* ]]
}

# ── 警告が家老に届く形（軍師一号 17:51 の名指し）────────────────────────

@test "G1 読み手が重ね送りを数えて出す（--dup-only は1行、rc は常に 0）" {
  bash "$REPO/scripts/ntfy.sh" "G1 題" "同じ本文" >/dev/null 2>&1
  bash "$REPO/scripts/ntfy.sh" "G1 題" "同じ本文" >/dev/null 2>&1
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE" --dup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"[NTFY-SEND-DUP]"* ]]
  [[ "$output" == *"1 件"* ]]
  [[ "$output" == *"呼び手="* ]]        # 誰が撃ったかも出る
}

@test "G2 重ね送りが無ければ 0 件と出る（常に鳴る警告ではない）" {
  bash "$REPO/scripts/ntfy.sh" "G2 題" "本文 A" >/dev/null 2>&1
  bash "$REPO/scripts/ntfy.sh" "G2 題" "本文 B" >/dev/null 2>&1
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE" --dup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 件"* ]]
}

@test "G3 重ね送りは判定を赤にしない（届いていないことではないため）" {
  NTFY_DRY_RUN=0 FAKE_MODE=ok bash "$REPO/scripts/ntfy.sh" "G3 題" "同じ本文" >/dev/null 2>&1
  NTFY_DRY_RUN=0 bash "$REPO/scripts/ntfy.sh" "G3 題" "同じ本文" >/dev/null 2>&1
  run python3 "$REPO/scripts/gate_ntfy_sendlog.py" --log-file "$NTFY_LOG_FILE"
  [ "$status" -eq 0 ]                    # PASS のまま
  [[ "$output" == *"[NTFY-SEND-DUP]"* ]] # 而して重ね送りは必ず出る
  [[ "$output" == *"[NTFY-SEND-OK]"* ]]
}
