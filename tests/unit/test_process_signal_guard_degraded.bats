#!/usr/bin/env bats
# test_process_signal_guard_degraded.bats — ★門が【退化して走っておる事】を名乗るかを縛る★ (cmd_1411 (b))
#
# ★なぜ此の試験が在るか (軍師一号 09:5x の実測・己が現に踏んだ経路)★:
#   process_signal_guard は tokenizer を兄弟 (shell_expansion_guard) から借りておる。
#   ★其の import が壊れた時、此の門は【盲になる】のではなく【喧しくなる】★=
#     兄弟なし版の selftest ★34/62・NG 28 = 過剰に拒む 24 / 見落とす 4★
#   ⇒ ★安全の向きは良い。而して cmd_1388 の族 (塞ぎ過ぎた禁は外される) の入口そのもの★
#   ⇒ ★喧しさの出所が判らねば、手は「禁を外す」へ向く★ =
#     ★★ゆえに門自身に「之は禁が辛いのではない・直す先は import である」と名乗らせた★★。
#
# ★此の試験が縛るのは【名乗り】であって【判定】ではない★=
#   判定の側 (62 件の両側撃ち) は --selftest が持つ。★此処は「退化を黙って起こさぬ」一点のみ★。
#
# ★作法★:
#   (a)★退化した盤面を【現に作る】★= 門だけを空の dir へ複写する = ★兄弟が居らぬゆえ import が現に落ちる★
#      (mock で _TOKENIZER_OK を偽装せぬ = ★偽装した盤面の緑は緑ではない★)
#   (b)★両側を撃つ★= ★健全な盤面では一言も出さぬ事★も縛る (cmd_1388 = 常に鳴る門を作らぬ)
#   (c)★bare `!` を使わぬ★ (cmd_1401) = 判定は `if <cmd>; then return 1; fi` の形で書く
#
# 契約:
#   T-PSG-001: ★退化 + 拒む形★ → rc=2 かつ ★拒みの便そのものに名乗りが載る★
#              (= exit 2 の stderr は必ず呼び手へ返る = 喧しさの出所が同梱される)
#   T-PSG-002: ★退化 + 通す形★ → rc=0 でも ★名乗りは出る★ (黙って退化させぬ)
#   T-PSG-003: ★健全 + 拒む形★ → rc=2 かつ ★名乗りは一つも出ぬ★ (常に鳴る門にせぬ)
#   T-PSG-004: ★健全 + 通す形★ → rc=0 かつ ★出力が一切 無い★
#   T-PSG-005: ★canary★= 退化した盤面が現に退化しておる (selftest が 62/62 にならぬ) =
#              ★之が緑のままなら T-PSG-001/002 は【何も撃っておらぬ】★

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GUARD="$REPO_ROOT/scripts/process_signal_guard.py"
  BANNER='退化して走っておる'
  # ★退化した盤面を現に作る★ = 兄弟を置かぬ dir へ門だけを複写する
  DEGRADED_DIR="$BATS_TEST_TMPDIR/degraded"
  mkdir -p "$DEGRADED_DIR"
  cp "$GUARD" "$DEGRADED_DIR/"
  DEGRADED="$DEGRADED_DIR/process_signal_guard.py"
}

# hook の実口 (stdin JSON) を其のまま使う = ★試験だけが通る裏口を作らぬ★
_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

@test "T-PSG-005 canary: 退化した盤面が現に退化しておる (selftest が満点にならぬ)" {
  run bash -c "python3 '$DEGRADED' --selftest 2>&1"
  # ★満点なら退化しておらぬ = 以下の試験は空撃ちである★
  if printf '%s' "$output" | grep -q '62/62 PASS'; then
    echo "★退化した筈の盤面が満点である = 複写だけでは import が落ちておらぬ★"
    return 1
  fi
  printf '%s' "$output" | grep -q 'NG'
}

@test "T-PSG-001 退化 + 拒む形: rc=2 かつ★拒みの便そのもの★に名乗りが載る" {
  payload="$(_payload 'kill -9 12345')"
  run bash -c "printf '%s' \"\$1\" | python3 '$DEGRADED' 2>&1 >/dev/null" _ "$payload"
  [ "$status" -eq 2 ]
  # ★★初版は此処で stderr 全体を grep しておった = 【何も証しておらなんだ】★★
  #   ★main の名乗りだけでも緑になるゆえ、拒みの便への同梱を落とす変異が生き残った★
  #   (2026-07-27 12:4x・六号が己の変異試験で捕らえた = ★緑の試験が証を持たぬ三類型の一つ★)
  #   ⇒ ★★拒みの見出しより【後ろ】に名乗りが在るかを見る★★ = 便に同梱された物だけを数える。
  after_header="$(printf '%s\n' "$output" | sed -n '/関所 (cmd_1411) が止めた/,$p')"
  if [ -z "$after_header" ]; then
    echo "★拒みの見出しが見当たらぬ = 此の試験の前提が崩れておる★"
    return 1
  fi
  printf '%s' "$after_header" | grep -q "$BANNER"
  # ★出所だけでなく【手の向き】まで名乗る★
  printf '%s' "$after_header" | grep -q '直す先は import'
}

@test "T-PSG-002 退化 + 通す形: rc=0 でも名乗りは出る (黙って退化させぬ)" {
  payload="$(_payload 'ls -la /tmp')"
  run bash -c "printf '%s' \"\$1\" | python3 '$DEGRADED' 2>&1 >/dev/null" _ "$payload"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "$BANNER"
}

@test "T-PSG-003 健全 + 拒む形: rc=2 かつ名乗りは一つも出ぬ" {
  payload="$(_payload 'kill -9 12345')"
  run bash -c "printf '%s' \"\$1\" | python3 '$GUARD' 2>&1 >/dev/null" _ "$payload"
  [ "$status" -eq 2 ]
  if printf '%s' "$output" | grep -q "$BANNER"; then
    echo "★健全なのに退化の名乗りが出た = 常に鳴る門である (cmd_1388 の族)★"
    return 1
  fi
}

@test "T-PSG-004 健全 + 通す形: rc=0 かつ出力が一切 無い" {
  payload="$(_payload 'ls -la /tmp')"
  run bash -c "printf '%s' \"\$1\" | python3 '$GUARD' 2>&1" _ "$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
