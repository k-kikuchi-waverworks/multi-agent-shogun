#!/usr/bin/env bats
# test_inbox_unread_count_anchor.bats — ★未読の数え方が【中身を見ずに数を返す】形へ戻らぬための門★
#
# ★本 file が生まれた実測 (2026-07-27 17:2x・足軽四号)★
#   止め番 (stop_hook_inbox.sh) は素の `grep -c 'read: false'` で未読を数えておった。
#   ⇒ ★本文に「read: false」という文字列を書いた便が【未読 1 件】に数えられた★
#   ⇒ 実害 = ★四号 = 真の未読 0 なのに止められ続けた★ / ★家老 = 9 対 8 (家老自身が膨らんだ数を受けておった)★
#   ⇒ 同じ数え方は nudge の数 (inbox_write.sh) にも在った = ★全軍の計器が膨らんでおった★。
#   14 inbox の実測 (撃つ前) = ★素 grep は 10/14 で真値と割れ・行頭錨つきは 14/14 一致★。
#
# ★錨が効く【理】★ = inbox の entry 欄は 2 空白で字下げされ、★本文 (content) は block scalar ゆえ
#   必ず更に深く (4 空白以上) 入る★。★ゆえに理そのものを T-3 が門として検める★
#   = ★之が無ければ「減った」の根拠が inbox_write.sh の実装へ暗黙に寄り掛かる★
#     (書き方が変わった日に、誰にも名乗らずに元の族へ戻る)。
#
# ★この file の中で【役割が違う】ことを先に書く（軍師一号 17:48 の名指し）★
#   T-101〜T-103 = ★数え方の説明★である。式をこの file の中に書き直して試しており、
#     ★監視スクリプト本体（stop_hook_inbox.sh）は走らせていない★
#     = ここが緑でも「止め番が直った」証拠にはならない。
#   T-201     = 錨が効く【理】（欄は 2 空白 / 本文は 4 空白以上）を、道具に現物を書かせて検める。
#   ★T-301    = 再発防止の本体★である。共有スクリプトに素の数え方が 1 つも残っていないことを
#     repo 全体で見るため、誰かが素の数え方へ戻した日にここが赤くなる。
#   ⇒ ★実際に再発を防いでいるのは T-301 であり、T-101〜103 はその説明である★。
#
# ★変異で牙を検めた (家老の枷)★
#   ① 真の未読 1 件を作れば ★止める (赤)★  ② 本文に「(read: false)」と書いても ★止めぬ (緑)★
#   ⇒ 之が本件の当の対照である。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export IW="$PROJECT_ROOT/scripts/inbox_write.sh"
    [ -f "$IW" ] || return 1
}

setup() {
    TESTDIR="$(mktemp -d)"
}

teardown() {
    [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
}

# 実装と同一の数え式 (錨つき)。★試験と実装で式が割れぬよう、此処にだけ書く★。
count_unread() {
    grep -cE '^  read: false' "$1" 2>/dev/null || true
}

# 真値 (YAML として読む)。★grep は近道であり、真値は構造から採る★。
count_unread_truth() {
    python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1])) or {}
print(sum(1 for e in (d.get('messages') or []) if isinstance(e,dict) and e.get('read') is False))
" "$1"
}

@test "T-101: 真の未読 1 件は現に数えられる (牙が在る = 赤を出せる)" {
    cat > "$TESTDIR/a.yaml" <<'EOF'
messages:
- content: "ただの便にて候。\n"
  from: karo
  read: false
  timestamp: '2026-07-27T17:00:00'
  type: instruction
EOF
    [ "$(count_unread "$TESTDIR/a.yaml")" -eq 1 ]
    [ "$(count_unread_truth "$TESTDIR/a.yaml")" -eq 1 ]
}

@test "T-102: ★本文に read: false と書かれた既読便は数えぬ★ (幻の未読が消えた当の対照)" {
    cat > "$TESTDIR/b.yaml" <<'EOF'
messages:
- content: "★貴殿が未だ読んでおらぬ (read: false) ゆえ、今なら 1 便で安く直る★\n"
  from: karo
  read: true
  timestamp: '2026-07-27T17:05:00'
  type: instruction
EOF
    # 素の数え方であれば 1 (幻) になる = 之が直した当の穴
    [ "$(grep -c 'read: false' "$TESTDIR/b.yaml")" -eq 1 ]
    # 錨つきは 0 = 真値と一致
    [ "$(count_unread "$TESTDIR/b.yaml")" -eq 0 ]
    [ "$(count_unread_truth "$TESTDIR/b.yaml")" -eq 0 ]
}

@test "T-103: 幻と真が混在しても、錨つきは真値だけを数える" {
    cat > "$TESTDIR/c.yaml" <<'EOF'
messages:
- content: "既読の便。本文に read: false と書いてある。\n"
  from: karo
  read: true
  timestamp: '2026-07-27T17:05:00'
  type: instruction
- content: "こちらが真の未読。\n"
  from: karo
  read: false
  timestamp: '2026-07-27T17:06:00'
  type: instruction
EOF
    [ "$(count_unread "$TESTDIR/c.yaml")" -eq "$(count_unread_truth "$TESTDIR/c.yaml")" ]
    [ "$(count_unread "$TESTDIR/c.yaml")" -eq 1 ]
}

@test "T-201: ★錨が効く理を門にする★ = 道具が現に書く形は「欄=2 空白 / 本文=4 空白以上」" {
    # ★実装 (inbox_write.sh) に現物を書かせ、其の字下げを検める★
    #   = 書き方が変わった日に、此の門が先に赤くなる (黙って族へ戻らせぬ)。
    # ★実 agent の inbox は一切使わぬ★ = 道具を隔離した木へ写して撃つ (cmd_1371 の作法)
    mkdir -p "$TESTDIR/scripts" "$TESTDIR/queue/inbox"
    cp "$IW" "$TESTDIR/scripts/"
    export TMUX_PANE="%zzz_test_unread_anchor"   # 鍵を盤面から借りぬ (cmd_1408 の是正に倣う)
    bash "$TESTDIR/scripts/inbox_write.sh" zzz_stub_unread_anchor --body-stdin instruction karo <<'BODY' >/dev/null 2>&1 || true
本文の一行目。
read: false と本文に書いてみる。
BODY
    F="$TESTDIR/queue/inbox/zzz_stub_unread_anchor.yaml"
    [ -f "$F" ]
    # entry の欄 (read:/from:/type: 等) は ★2 空白★
    grep -qE '^  read: (false|true)$' "$F"
    # 本文の行は ★4 空白以上★ (block scalar の内側) = 2 空白ちょうどの本文行は在ってはならぬ
    run bash -c "grep -nE '^  [^ ].*read: false' '$F' | grep -v '^[0-9]*:  read: false\$'"
    [ -z "$output" ]
    # 真値と錨つきが一致 (書かれた便は未読 1 件)
    [ "$(count_unread "$F")" -eq "$(count_unread_truth "$F")" ]
}

@test "T-301: ★共有 script に素の数え方が 1 つも残っておらぬ★ (族の再発を repo 全体で塞ぐ)" {
    run bash -c "grep -rnE \"grep -c ['\\\"]read: (false|true)\" '$PROJECT_ROOT/scripts' || true"
    [ -z "$output" ]
}
