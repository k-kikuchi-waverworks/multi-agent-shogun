#!/usr/bin/env bats
# cmd_1420 — 送る前に題と本文を検める（2026-07-27 足軽四号）
#
# 実測（軍師二号 plans/cmd_1420_ntfy_readability.md）: 本日の実送信24本のうち、
#   殿の基準（題20字以内・本文3行以内・平易語・記号を並べない）を満たしたのは3本だけ。
#   題の平均は26字、最長41字であった。
#
# ここで固めること:
#   ・外れているときは必ず画面に出る（そして送信は止めない）
#   ・満たしているときは黙る（常に鳴る警告ではない）
#   ・バッククォートで囲んでも通らない（engine 側で本日 現に踏んだ穴を、ここでは作らない）
#   ・判定を外すと赤になる（この試験に牙があるか）
#
# 送信は乾式（NTFY_DRY_RUN=1）。ntfy へは1本も飛ばない。本番ログは触らない。

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  export NTFY_LOG_FILE="$TMP/ntfy_send.log"
  export NTFY_DRY_RUN=1          # 乾式。curl は呼ばれない
  REAL_LOG="$REPO/logs/ntfy_send.log"
  REAL_MD5_BEFORE="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"
  unset TMUX_PANE
}

teardown() {
  local after
  after="$(md5sum "$REAL_LOG" 2>/dev/null | awk '{print $1}')"
  [ "$REAL_MD5_BEFORE" = "$after" ] || {
    echo "本番ログが変わっている" >&2
    return 1
  }
  rm -rf "$TMP"
}

# ── 題の字数 ────────────────────────────────────────────────────────────

@test "L1 41字の題は外れとして画面に出る（実際に送られた最長の題）" {
  run bash "$REPO/scripts/ntfy.sh" "🚨 殿の手番が一つ増え申した (A-6) — 恋の頭脳 v7.1 に durabl" "本文"
  [ "$status" -eq 0 ]                    # 送信は止めない
  [[ "$output" == *"題が"*"字ある"* ]]
  run grep -c 'style=[^ ]*len' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]                    # ログにも残る
}

@test "L2 20字ちょうどの題は何も言わない（常に鳴る警告ではない）" {
  # 20字（コードポイント数え）
  local t="あいうえおかきくけこさしすせそたちつて完"
  [ "$(printf '%s' "$t" | wc -m | tr -d ' ')" -eq 20 ]
  run bash "$REPO/scripts/ntfy.sh" "$t" "本文"
  [ "$status" -eq 0 ]
  [[ "$output" != *"題が"* ]]
  run grep -c 'style=ok' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "L3 21字なら言う（境目で切れている）" {
  local t="あいうえおかきくけこさしすせそたちつてと完"
  [ "$(printf '%s' "$t" | wc -m | tr -d ' ')" -eq 21 ]
  run bash "$REPO/scripts/ntfy.sh" "$t" "本文"
  [[ "$output" == *"題が 21 字ある"* ]]
}

@test "L4 絵文字は1字と数える（数え方を決めて書いた通りか）" {
  # 絵文字1 + 19字 = 20字 ＝ 外れない
  local t="✅あいうえおかきくけこさしすせそたちつて"
  [ "$(printf '%s' "$t" | wc -m | tr -d ' ')" -eq 20 ]
  run bash "$REPO/scripts/ntfy.sh" "$t" "本文"
  [[ "$output" != *"題が"* ]]
}

# ── 本文の行数 ──────────────────────────────────────────────────────────

@test "B1 本文4行は外れとして出る" {
  run bash "$REPO/scripts/ntfy.sh" "完了しました" "$(printf '一行\n二行\n三行\n四行')"
  [[ "$output" == *"本文が 4 行ある"* ]]
}

@test "B2 本文3行は言わない" {
  run bash "$REPO/scripts/ntfy.sh" "完了しました" "$(printf '一行\n二行\n三行')"
  [[ "$output" != *"本文が"* ]]
}

# ── 記号・文語調・身内の言い回し ────────────────────────────────────────

@test "S1 題の記号（★）は外れ" {
  run bash "$REPO/scripts/ntfy.sh" "★★ 完了 ★★" "本文"
  [[ "$output" == *"記号"* ]]
}

@test "S2 普通の括弧は外れではない（何にでも当たる判定にしない）" {
  # ★最初の版は ? を裸で書いたため glob の1文字扱いになり、正しい題まで外れと言った★
  run bash "$REPO/scripts/ntfy.sh" "✅ 株 T3 完了（データ不足 56%）" "本文"
  [[ "$output" != *"記号"* ]]
  run grep -c 'style=ok' "$NTFY_LOG_FILE"
  [ "$output" = "1" ]
}

@test "S3 文語調の語は外れ（本文の側にあっても見る）" {
  run bash "$REPO/scripts/ntfy.sh" "完了しました" "作業が終わってござる"
  [[ "$output" == *"文語調"* ]]
}

@test "S4 身内の言い回しは外れ" {
  run bash "$REPO/scripts/ntfy.sh" "完了しました" "門を通しました"
  [[ "$output" == *"身内の言い回し"* ]]
}

@test "S5 バッククォートで囲んでも通らない（engine で踏んだ穴を作らない）" {
  run bash "$REPO/scripts/ntfy.sh" "完了しました" '`門` を通し `ござる`'
  [[ "$output" == *"文語調"* ]]
  [[ "$output" == *"身内の言い回し"* ]]
}

# ── 送信を止めないこと・型の読み口 ──────────────────────────────────────

@test "N1 外れがあっても送信は止まらない（急ぎの知らせを文体で殺さない）" {
  run bash "$REPO/scripts/ntfy.sh" "⛔ 作業が止まり申した — GPU を掴んだままでござる (cmd_9999)" "本文"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NTFY_LOG_FILE")" -eq 1 ]   # 記録も残る
}

@test "N2 外れた時は型の在り処を出す" {
  run bash "$REPO/scripts/ntfy.sh" "★ 完了でござる ★" "本文"
  [[ "$output" == *"cmd_1420_ntfy_templates.md"* ]]
}

@test "N3 --templates で型が読める（呼び手が使える形）" {
  run bash "$REPO/scripts/ntfy.sh" --templates
  [ "$status" -eq 0 ]
  [[ "$output" == *"型1 — 完了報告"* ]]
  [[ "$output" == *"型5 — 訂正"* ]]
  [ ! -f "$NTFY_LOG_FILE" ]                 # 型を読むだけで送信の記録は作らない
}

@test "N4 判定の結果はログに残り、読み手も読める" {
  bash "$REPO/scripts/ntfy.sh" "★ 完了でござる ★" "本文" >/dev/null 2>&1
  run python3 - "$REPO" "$NTFY_LOG_FILE" <<'PY'
import importlib.util, pathlib, sys
repo, log = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("g", repo / "scripts/gate_ntfy_sendlog.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
g = m.LINE_RE.match(log.read_text(encoding="utf-8").splitlines()[0])
assert g, "読めない"
assert g.group("style") and "sym" in g.group("style"), g.groupdict()
print("ok")
PY
  [ "$status" -eq 0 ]
}

# ── 変異（この試験に牙があるか）────────────────────────────────────────

make_tree() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/lib" "$dir/config"
  cp "$REPO/scripts/ntfy.sh" "$dir/scripts/"
  cp "$REPO/lib/ntfy_auth.sh" "$dir/lib/"
  printf 'ntfy_topic: "zzz_test_topic_1420"\n' > "$dir/config/settings.yaml"
}

@test "M1 字数の判定を外すと L1 の主張が落ちる" {
  make_tree "$TMP/mut1"
  # 変異前の写しでは出る
  NTFY_LOG_FILE="$TMP/mut1/before.log" run bash "$TMP/mut1/scripts/ntfy.sh" "あいうえおかきくけこさしすせそたちつてとな完了" "本文"
  [[ "$output" == *"題が"* ]]
  # 判定を外す（閾値を届かない値へ）
  sed -i 's/-gt 20 \]; then/-gt 99999 ]; then/' "$TMP/mut1/scripts/ntfy.sh"
  NTFY_LOG_FILE="$TMP/mut1/after.log" run bash "$TMP/mut1/scripts/ntfy.sh" "あいうえおかきくけこさしすせそたちつてとな完了" "本文"
  [[ "$output" != *"題が"* ]]        # 現に落ちる = L1 は牙を持っている
  [ "$(wc -l < "$TMP/mut1/after.log")" -eq 1 ]   # 送信そのものは動いている
}

@test "M2 文語調の一覧を空にすると S3 の主張が落ちる" {
  make_tree "$TMP/mut2"
  NTFY_LOG_FILE="$TMP/mut2/before.log" run bash "$TMP/mut2/scripts/ntfy.sh" "完了しました" "終わってござる"
  [[ "$output" == *"文語調"* ]]
  sed -i 's/^for _w in 申し ござ 而して 拙者 貴殿 候 なされ; do/for _w in ; do/' "$TMP/mut2/scripts/ntfy.sh"
  NTFY_LOG_FILE="$TMP/mut2/after.log" run bash "$TMP/mut2/scripts/ntfy.sh" "完了しました" "終わってござる"
  [[ "$output" != *"文語調"* ]]
}
