#!/usr/bin/env bats
# test_cmd1371_body_transport.bats — ★本文の【口】と、関所の生死の名乗り★ (cmd_1371)
#
# ★本 cmd が生まれた実測★
#   cmd_1363 は口(A)(B)(C)(D)を正しく塞ぎ、逃げ道 (--body-stdin / --content-file) も
#   道具側に実装済であった。にもかかわらず 2026-07-26 の一日で
#   ★関所が DENY と判ずる命令 21 件のうち 19 件がすり抜けた★
#   (本日分の全 session 記録を走査して実測 — plans/cmd_1371_guard_leak_census.json)。
#   ★是正 2026-07-26 16:26: 初版は 38/2/36 と書いた = 過大であった★
#     (a)file 単位で数え resume/compaction の写しを重複計上 (生38→unique28)
#     (b)絞りが file mtime のみゆえ 07-25 の record を本日分に混ぜた (unique28 中 7 件)
#     ⇒ 21 = 2 + 19 (検算つき)。★結論は不変 = 19 は 2 の約10倍★。
#     割れたのは総数だけ (止めた2件の時刻・すり抜けた最後 05:23:30Z は一致)。
#   四号の原文を採り出して関所へ食わせると ★DENY★ =
#   ★関所は正しく判じておった。呼ばれておらなんだだけである★。
#   ⇒ ★穴は「関所が無いこと」でなく【関所が在るのに効いておるか誰も知らぬこと】★。
#
# ★判ずる基準は【中身の突合】★ = exit code を信じてはならぬ (五号の具申)。
#   本件の型は送信が成功したまま (exit 0 / [OK]) 中身だけ変わるゆえ。
#
# 構成:
#   T-1xx = 安全な口 (stdin / file) が ★原文どおり★ 運ぶか (byte一致・末尾改行まで)
#   T-2xx = 危うい口 (argv) の後方互換と、★食われる形の対照★
#   T-3xx = 札 (via / guard / safety) が実態と合うておるか ★緑も赤も出せること★
#   T-4xx = 強制の口 (IW_REQUIRE_SAFE_BODY) と、その下でも逃げ場が在ること
#
# ★変異試験★ = 本 file の牙は config/mutation_registry.yaml の MUT-1371-* に登録済。
#   わざと壊して赤くなることを実測してから登録した (登録の作法・2026-07-26 全軍規律)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export IW="$PROJECT_ROOT/scripts/inbox_write.sh"
    export GUARD="$PROJECT_ROOT/scripts/shell_expansion_guard.py"
    [ -f "$IW" ] || return 1
    [ -f "$GUARD" ] || return 1
}

setup() {
    TESTDIR="$(mktemp -d)"
    mkdir -p "$TESTDIR/scripts" "$TESTDIR/queue/inbox"
    cp "$IW" "$TESTDIR/scripts/"
    export TESTDIR
    export STUB="zzz_stub_target_1371"   # ★実 agent の inbox は一切使わぬ★
    # 危うい綴りを全部入れた本文 (四号・五号が実際に踏んだ型を含む)
    BODY="$TESTDIR/body.txt"
    cat > "$BODY" <<'RAWEOF'
四号の型: `--num-processes` を実装し
五号の型: `.env` を読む
展開の型: $(echo EATEN_BY_SHELL) と ${HOME} と $UNDEFINED_VAR_XYZ
散文に紛れた型: port は $PORT_XYZ である
RAWEOF
    export BODY
    export HBDIR="$TESTDIR/queue/.shell_guard_heartbeat"
    # ═══ ★cmd_1408 是正 (2026-07-27 07:30 実測)★ ═══════════════════════════════
    # ★旧版★= HBKEY を `${TMUX_PANE:-nopane}` から採っておった = ★盤面から鍵を借りておった★。
    #   ・tmux の中で撃つ  = 道具も TMUX_PANE を鍵にするゆえ一致 → ★緑★
    #   ・cron の中で撃つ  = 道具は「pane も session も無い = outside-pane」へ落ち、
    #                        ★心拍を見に行かぬ★ → T-302/T-303 が赤
    #     (T-502 も同断 = 関所 python は TMUX_PANE 無しでは payload の session_id を鍵に採るゆえ
    #      "nopane" を見張っておる試験と鍵が割れる)
    #   ⇒ ★★試験の緑が【誰が走らせたか】に依っておった★★ = 毎朝の門で MUT-1371-001〜005/007 が
    #      ★永久に UNDETERMINED★ (baseline が赤ゆえ検出力を測れぬ) を出し続けておった。
    # ★書いた時の註 (T-502) は「隔離した木へ写せば心拍の在処も隔離される」と申しておった★=
    #   ★在処 (HBDIR) は現に隔離できておった。而して【鍵】は隔離しておらなんだ = 半分だけ隔離した形★。
    # ★処方★= ★鍵を盤面から借りず、試験の側で固定する★ = cron でも tmux でも同じ赤・同じ緑になる。
    #   (★TMUX_PANE を持たぬ経路そのものを検める T-307/T-308 は `env -u TMUX_PANE` で明示的に
    #     剥がしておるゆえ、此の固定に侵されぬ★ = ★盤面依存を消しても、盤面を検める口は残る★)
    export TMUX_PANE="%zzz_test_1371"
    export HBKEY="$(printf '%s' "$TMUX_PANE" | tr -c 'A-Za-z0-9_.-' '_')"
}

teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

_inbox() { echo "$TESTDIR/queue/inbox/${STUB}.yaml"; }

# 届いた entry の1つの field を取り出す
_field() {
    python3 -c '
import yaml,sys
d=yaml.safe_load(open(sys.argv[1])) or {}
m=(d.get("messages") or [{}])[-1]
v=m.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))
' "$(_inbox)" "$1"
}

# ★本文が原文と1 byte も違わぬか★ — 本 suite の中核判定
_content_matches_file() {
    python3 -c '
import yaml,sys,pathlib
d=yaml.safe_load(open(sys.argv[1])) or {}
got=(d.get("messages") or [{}])[-1].get("content")
want=pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
sys.exit(0 if got==want else 1)
' "$(_inbox)" "$1"
}

_fresh_heartbeat() { mkdir -p "$HBDIR"; printf '%s 1\n' "$(date +%s)" > "$HBDIR/$HBKEY"; }
_old_heartbeat()   { mkdir -p "$HBDIR"; printf '%s 1\n' "$(( $(date +%s) - 600 ))" > "$HBDIR/$HBKEY"; }

# ═══════════ T-1xx: 安全な口が原文どおり運ぶか ═══════════

@test "T-101: --body-stdin は危うい綴りを原文どおり運ぶ (末尾改行まで)" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh "$STUB" --body-stdin report ashigaru6 < "$BODY"
    _content_matches_file "$BODY"
}

@test "T-102: --content-file (空白区切り) も原文どおり" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh "$STUB" --content-file "$BODY" report ashigaru6
    _content_matches_file "$BODY"
}

@test "T-103: --body-file=PATH (= つき) も原文どおり" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh "$STUB" --body-file="$BODY" report ashigaru6
    _content_matches_file "$BODY"
}

@test "T-104: ★末尾改行が落ちぬ★ (command substitution が黙って剥がす穴)" {
    cd "$TESTDIR"
    printf 'ここで終わる\n' > "$TESTDIR/tail.txt"
    bash scripts/inbox_write.sh "$STUB" --body-stdin report ashigaru6 < "$TESTDIR/tail.txt"
    _content_matches_file "$TESTDIR/tail.txt"
}

# ── ★規模の層★ (cmd_1358 N4 の教訓を本 gate の軸で採る) ──────────────────
#   軍師一号が拙者の KAT に「規模の層が無い」と穴を空けた。その時 家老は
#   ★「大きい標本を足せ」でなく【そのgateが黙る規模の軸を選べ】★ を拙者の文言で採った。
#   ⇒ 本 gate が黙る軸は ★本文の大きさ★ である =
#     YAML は長い行を折り返す (dump→load で空白が変わりうる) ゆえ、
#     ★短い本文だけを標本にすると「長文だけが黙って変質する」形を見逃す★。
#     長文の本命こそ heredoc/file 経路ゆえ、この軸を欠けば守りの中心が無検査になる。

@test "T-105: ★規模の層★ 10万字級の長文が file 経路で原文どおり届く" {
    cd "$TESTDIR"
    python3 -c '
import sys
# 空白を含む長い【1行】 = YAML の折り返しが最も効く形
sys.stdout.write(("これは長い本文である ★危うい綴り $VAR と `backtick` を含む★ " * 2000))
' > "$TESTDIR/big.txt"
    [ "$(wc -c < "$TESTDIR/big.txt")" -gt 100000 ]
    bash scripts/inbox_write.sh "$STUB" --content-file "$TESTDIR/big.txt" report ashigaru6
    _content_matches_file "$TESTDIR/big.txt"
}

@test "T-106: ★規模の層★ 折り返しの効かぬ長大1行 (空白なし) も原文どおり" {
    cd "$TESTDIR"
    python3 -c 'import sys; sys.stdout.write("あ"*60000)' > "$TESTDIR/nospace.txt"
    bash scripts/inbox_write.sh "$STUB" --body-stdin report ashigaru6 < "$TESTDIR/nospace.txt"
    _content_matches_file "$TESTDIR/nospace.txt"
}

# ═══════════ T-2xx: 危うい口の後方互換と、食われる形の対照 ═══════════

@test "T-201: 後方互換 — 位置引数の平文呼出は今も通り、原文どおり届く" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh "$STUB" "軍師の検分は PASS であった" report ashigaru6
    printf '%s' "軍師の検分は PASS であった" > "$TESTDIR/plain.txt"
    _content_matches_file "$TESTDIR/plain.txt"
    [ "$(_field via)" = "argv" ]
}

@test "T-202: ★対照★ 位置引数 + 二重引用符は実際に食われる (本 cmd が在る理由)" {
    cd "$TESTDIR"
    # ★別 file の fixture で撃つ★ = bats 側で escape すれば食われず対照が崩れるゆえ。
    #   ★script の内側を関所は元より見ておらぬ★ = この経路が残っておることの実証でもある。
    cat > "$TESTDIR/eat.sh" <<'FIXEOF'
set +u
cd "$1" || exit 1
bash scripts/inbox_write.sh "$2" "四号の型: `echo EATEN` を実装し / 展開: $UNDEFINED_VAR_XYZ" report ashigaru6
FIXEOF
    bash "$TESTDIR/eat.sh" "$TESTDIR" "$STUB" >/dev/null 2>&1
    run _field content
    # backtick も未定義変数も消え、実行結果 EATEN が本文へ紛れ込んでおること
    [[ "$output" == *"EATEN"* ]]
    [[ "$output" != *'`'* ]]
    [[ "$output" != *'UNDEFINED_VAR_XYZ'* ]]
    [ "$(_field safety)" = "UNPROTECTED" ]
}
