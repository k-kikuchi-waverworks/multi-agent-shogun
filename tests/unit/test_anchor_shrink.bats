#!/usr/bin/env bats
# test_anchor_shrink.bats — ★錨を絞る口が【正しい物】を出すかを縛る★ (cmd_1387 系統・cmd_1413)
#
# ★何ゆえ此の口が在るか★:
#   六号が 12:55 に ★己の commit で己の牙 2 本の錨を鈍らせた★ (行末まで含む錨ゆえ hit=0)。
#   ★家老の裁 (13:11/13:12)★= ★一斉置換はせぬ★・★足す物は一つ = 触れる者が其の場で問える口★。
#   ⇒ scripts/anchor_shrink.py が其の口である。
#
# ★此の試験が縛るのは【出す物の正しさ】である★:
#   ★推しが一意でなければ、絞った其の日から牙は別の場所を撃つ★= ★鈍りを直して誤爆を作る形★
#   ⇒ ★一意性と「行末に接せぬ」の二つを、実物の file の上で毎度 検める★。
#
# ★作法★= (a) 現物を撃つ (mock せぬ) (b) 両側を撃つ (c) bare `!` を使わぬ (cmd_1401)
#
# 契約:
#   T-AS-000 canary : --selftest が 7/7 で通る (口そのものが壊れておらぬ)
#   T-AS-001 : 行末に接する錨 → ★推しを出し、其れは一意で行末に接せぬ★
#   T-AS-002 : 行末に接せぬ錨 → ★「絞る要は無い」と申す★ (常に絞れと申さぬ)
#   T-AS-003 : 盤面に無い錨 → ★診られなんだと申す★ (黙って通さぬ)
#   T-AS-004 : ★機械の最短を其のまま推さぬ★= 推しは機械の最短以上の長さで、且つ其の旨を刷る
#   T-AS-005 : --census が母数と「読めなんだ」を必ず刷る (0 と 読めぬ を分ける)

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TOOL="$PROJECT_ROOT/scripts/anchor_shrink.py"
  [ -f "$TOOL" ] || return 1
  WORK="$(mktemp -d "$BATS_TMPDIR/anchorshrink.XXXXXX")"
  # ★実物の形を写した盤面★ (同じ綴りが二度 出る = 一意性が問題になる形)
  printf 'if [ "$a" -eq 1 ]; then exit 1; fi\nif [ "$b" -ne 0 ]; then exit 2; fi\n' > "$WORK/t.sh"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

_shrink() { # $1=anchor
  printf '%s' "$1" > "$WORK/anchor.txt"
  python3 "$TOOL" --file t.sh --anchor-file "$WORK/anchor.txt" --repo-root "$WORK"
}

@test "T-AS-000 canary: --selftest が通る (口そのものが壊れておらぬ)" {
  run python3 "$TOOL" --selftest
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '7/7 PASS'
}

@test "T-AS-001 行末に接する錨 → 推しが出る (一意・行末に接せぬ)" {
  run _shrink 'if [ "$a" -eq 1 ]; then exit 1; fi'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '行末に接しておる'
  printf '%s' "$output" | grep -qF '★推し★'
  # ★出した推しを其の場で検め直す★= 一意であり、行末に接せぬこと
  rec="$(printf '%s\n' "$output" | sed -n "s/^★推し★ : [0-9]* 字 = '\(.*\)'$/\1/p")"
  if [ -z "$rec" ]; then echo "★推しを読み取れなんだ★"; return 1; fi
  # ★grep で検めるな★= ★改行を含む pattern は grep では【複数 pattern】に化ける★
  #   (2026-07-27 13:1x 実測 = 之で本試験の初版が偽の赤を出した = ★己の計器を先に疑う★)
  #   ⇒ 一意性と「行末に接せぬ」は python で数える。
  run python3 - "$WORK/t.sh" "$rec" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
rec = sys.argv[2]
i = s.find(rec)
assert s.count(rec) == 1, f"推しが一意でない (hit={s.count(rec)}) = ★絞って誤爆を作る形★"
assert s[i + len(rec)] != "\n", "推しが行末に接しておる = ★絞った意味が無い★"
print("OK")
PY
  [ "$status" -eq 0 ]
}

@test "T-AS-002 行末に接せぬ錨 → 「絞る要は無い」と申す (常に絞れと申さぬ)" {
  run _shrink 'if [ "$a" -eq 1 ]'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '絞る要は無い'
  if printf '%s' "$output" | grep -qF '★推し★'; then
    echo "★要らぬのに推しを出した = 常に鳴る門と同族★"; return 1
  fi
}

@test "T-AS-003 盤面に無い錨 → 診られなんだと申す (黙って通さぬ)" {
  run _shrink 'no_such_anchor_zzz'
  printf '%s' "$output" | grep -qF '診られなんだ'
  printf '%s' "$output" | grep -qF 'hit=0'
}

@test "T-AS-004 機械の最短を其のまま推さぬ (誤爆の穴を開けぬ)" {
  run _shrink 'if [ "$a" -eq 1 ]; then exit 1; fi'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '機械の最短を其のまま採るな'
  rec_len="$(printf '%s\n' "$output" | sed -n 's/^★推し★ : \([0-9]*\) 字.*/\1/p')"
  min_len="$(printf '%s\n' "$output" | sed -n 's/^(機械の最短 = \([0-9]*\) 字.*/\1/p')"
  [ -n "$rec_len" ] && [ -n "$min_len" ]
  [ "$rec_len" -ge "$min_len" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ★★以下 2 本は【初版が変異を素通りした】ゆえ後から足した★★ (2026-07-27 13:2x)
#   ★初版の見本では【機械の最短 = 推し】であり、且つ【行末に接する短い prefix】が存在せなんだ★
#   ⇒ ★「行末に接する prefix を弾く枝」を消しても★・★「推しを機械の最短へ倒し」ても★ 6/6 緑のままであった
#   = ★★本日 六号が二度 踏んだ「緑の試験が証を持たぬ」形の三度目★★
#   ⇒ ★見本の側を、其の枝が現に効く盤面へ作り直した★ (門でなく【見本】が弱かった)。
# ─────────────────────────────────────────────────────────────────────────────

@test "T-AS-006 短い一意 prefix が行末に接する盤面 → 推しは其れを採らぬ" {
  # ★"aa" は一意だが行末に接する★ ⇒ 採れば「絞った意味が無い」錨になる
  printf 'aa\nab\n' > "$WORK/t.sh"
  printf '%s' 'aa
ab' > "$WORK/anchor.txt"
  run python3 "$TOOL" --file t.sh --anchor-file "$WORK/anchor.txt" --repo-root "$WORK"
  [ "$status" -eq 0 ]
  rec="$(printf '%s\n' "$output" | sed -n "s/^★推し★ : [0-9]* 字 = \(.*\)$/\1/p")"
  if [ -z "$rec" ]; then echo "★推しを出しておらぬ★"; return 1; fi
  # ★推しに改行が含まれておること★= 行末に接する "aa" で止めておらぬ証
  if printf '%s' "$rec" | grep -qF "'aa'"; then
    echo "★行末に接する prefix を推した = 絞った意味が無い★"; return 1
  fi
}

@test "T-AS-007 機械の最短が識別子の途中で切れる盤面 → 推しは語の切れ目まで延ばす" {
  printf 'alpha_beta_gamma = 1\nalpha_zeta = 2\n' > "$WORK/t.sh"
  printf '%s' 'alpha_beta_gamma = 1' > "$WORK/anchor.txt"
  run python3 "$TOOL" --file t.sh --anchor-file "$WORK/anchor.txt" --repo-root "$WORK"
  [ "$status" -eq 0 ]
  rec_len="$(printf '%s\n' "$output" | sed -n 's/^★推し★ : \([0-9]*\) 字.*/\1/p')"
  min_len="$(printf '%s\n' "$output" | sed -n 's/^(機械の最短 = \([0-9]*\) 字.*/\1/p')"
  [ -n "$rec_len" ] && [ -n "$min_len" ]
  # ★機械の最短 = "alpha_b" (7 字・識別子の途中)★ / ★推し = "alpha_beta_gamma" (16 字)★
  [ "$min_len" -lt "$rec_len" ]
  printf '%s' "$output" | grep -qF "'alpha_beta_gamma'"
}

@test "T-AS-005 --census は母数と【読めなんだ】を必ず刷る" {
  run python3 "$TOOL" --census
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '★母数★'
  printf '%s' "$output" | grep -qF '読めなんだ'
  printf '%s' "$output" | grep -qF '数えられておらぬ = 0 ではない'
}
