#!/usr/bin/env bats
# inbox_write の overflow（50通 超過時の間引き）で、既読を捨てる前に退避しているかを検める。
#
# なぜ要るか（2026-07-27 夜・家老の命）:
#   配達の道具は 50通 を超えると既読を黙って捨てていた。退避は 07-25 で止まっている。
#   未読は落とさぬゆえ実害は軽いが、「後から遡れぬ」点は錠なしの書き換えと同じである。
#
# ★2026-07-28 07:xx (cmd_1458)= 直した形を本体へ据えた。ゆえに既定を本体へ向け、staging から此処へ移した。★
#   移した先が tests/unit/ ゆえ、.gitignore:490 の `!tests/unit/*.bats` で追跡下に入る（白名簿へ足す行は要らぬ）。
#
# 検める先は環境変数 IW_UNDER_TEST で差し替えられる（既定 = 本体 scripts/inbox_write.sh）。
#   ・本体（据えた形）        → 全部 緑
#   ・退避を外した形（作り物） → 赤（＝この試験は現に穴を捕まえる。据える前は本体そのものが此の形であった）
#   ・件数を偽った形          → 赤
#
# 生きている queue には一切 触らない。毎回 使い捨ての木を建ててその中だけで撃つ。

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SUT_SRC="${IW_UNDER_TEST:-$REPO_ROOT/scripts/inbox_write.sh}"
    [ -f "$SUT_SRC" ] || { echo "SUT not found: $SUT_SRC" >&2; return 1; }

    FAKE_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/queue/inbox"
    cp "$SUT_SRC" "$FAKE_ROOT/scripts/inbox_write.sh"
    SUT="$FAKE_ROOT/scripts/inbox_write.sh"
    INBOX="$FAKE_ROOT/queue/inbox/karo.yaml"
    ARCHIVE_DIR="$FAKE_ROOT/queue/archive"
}

# 既読 N 通を積んだ inbox を建てる（id は seed_000 … の連番）
seed_inbox() {
    local n="$1"
    SEED_N="$n" INBOX="$INBOX" python3 - <<'PY'
import os, yaml
n = int(os.environ["SEED_N"])
msgs = [{
    "id": "seed_%03d" % i,
    "from": "ashigaru9",
    "timestamp": "2026-07-27T00:%02d:00" % (i % 60),
    "type": "notice",
    "content": "本文 %d\n" % i,
    "read": True,
} for i in range(n)]
with open(os.environ["INBOX"], "w") as f:
    yaml.dump({"messages": msgs}, f, default_flow_style=False, allow_unicode=True, indent=2)
PY
}

ids_in() {
    F="$1" python3 -c '
import os, yaml
with open(os.environ["F"]) as f:
    d = yaml.safe_load(f) or {}
for m in (d.get("messages") or []):
    print(m.get("id"))
'
}

count_in() { ids_in "$1" | grep -c . || true; }

@test "溢れた時、捨てた既読が退避 file に残る" {
    seed_inbox 60
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]

    # 退避 file が1本 出来ている
    shopt -s nullglob
    local arcs=("$ARCHIVE_DIR"/inbox_karo_*_overflow*.yaml)
    [ "${#arcs[@]}" -eq 1 ]

    # 残った 31通（未読1 + 既読30）／退避 30通
    [ "$(count_in "$INBOX")" -eq 31 ]
    [ "$(count_in "${arcs[0]}")" -eq 30 ]

    # 退避されたのは古い方 30通である
    [ "$(ids_in "${arcs[0]}" | head -1)" = "seed_000" ]
    [ "$(ids_in "${arcs[0]}" | tail -1)" = "seed_029" ]
}

@test "1通も消えない（inbox + 退避 = 元の全部 + 新しい1通）" {
    seed_inbox 60
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]

    shopt -s nullglob
    local arcs=("$ARCHIVE_DIR"/inbox_karo_*_overflow*.yaml)
    [ "${#arcs[@]}" -eq 1 ]

    local after
    after="$( { ids_in "$INBOX"; ids_in "${arcs[0]}"; } | sort -u | grep -c . )"
    # 元 60 + 新しい 1 = 61 種類の id が、どこかに必ず在る
    [ "$after" -eq 61 ]

    local i
    for i in 000 001 029 030 059; do
        { ids_in "$INBOX"; ids_in "${arcs[0]}"; } | grep -qx "seed_$i"
    done
}

@test "何通 捨てたかを出す。その数が実際と合っている" {
    seed_inbox 60
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]

    # 出力に「overflow」の行が在る
    echo "$output" | grep -q "overflow"

    # 出力の数字と、実際に減った数が一致する
    local claimed actual
    claimed="$(echo "$output" | sed -n 's/.*overflow: 既読 \([0-9]\+\) 通.*/\1/p' | head -1)"
    [ -n "$claimed" ]
    actual=$(( 60 + 1 - $(count_in "$INBOX") ))
    [ "$claimed" -eq "$actual" ]

    # 退避 file の実件数とも一致する
    shopt -s nullglob
    local arcs=("$ARCHIVE_DIR"/inbox_karo_*_overflow*.yaml)
    [ "$claimed" -eq "$(count_in "${arcs[0]}")" ]
}

@test "溢れぬ時は退避 file を作らない" {
    seed_inbox 10
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]
    [ "$(count_in "$INBOX")" -eq 11 ]
    shopt -s nullglob
    local arcs=("$ARCHIVE_DIR"/inbox_karo_*_overflow*.yaml)
    [ "${#arcs[@]}" -eq 0 ]
}

@test "未読は溢れても1通も落ちない（従来の約束を壊していない）" {
    # 既読 60 + 未読 5 を積む
    seed_inbox 60
    INBOX="$INBOX" python3 - <<'PY'
import os, yaml
p = os.environ["INBOX"]
with open(p) as f:
    d = yaml.safe_load(f)
for i in range(5):
    d["messages"].append({
        "id": "unread_%d" % i, "from": "ashigaru9",
        "timestamp": "2026-07-27T01:00:00", "type": "notice",
        "content": "未読 %d\n" % i, "read": False,
    })
with open(p, "w") as f:
    yaml.dump(d, f, default_flow_style=False, allow_unicode=True, indent=2)
PY
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]
    local i
    for i in 0 1 2 3 4; do
        ids_in "$INBOX" | grep -qx "unread_$i"
    done
}

@test "退避が書けぬ時、1通も消えず、かつ配達が通る（家老 20:10 の裁）" {
    seed_inbox 60
    # 退避先を file にしておく = mkdir も書き込みも通らぬ
    printf 'x' > "$ARCHIVE_DIR"
    run bash "$SUT" karo "新しい便" notice ashigaru1

    # (1) 配達は通る。止めるのは【切り詰め】であって【配達】ではない
    [ "$status" -eq 0 ]
    # 新しい便が現に着いている
    F="$INBOX" python3 -c '
import os, yaml, sys
with open(os.environ["F"]) as f:
    d = yaml.safe_load(f) or {}
sys.exit(0 if any(m.get("content") == "新しい便" for m in (d.get("messages") or [])) else 1)
'
    # (2) 既読は1通も消えていない。60 + 新しい 1 = 61 通が inbox に在る
    [ "$(count_in "$INBOX")" -eq 61 ]
    ids_in "$INBOX" | grep -qx "seed_000"
    ids_in "$INBOX" | grep -qx "seed_029"
}

@test "見送った事を黙って済ませない（何通 越えているかも出す）" {
    seed_inbox 60
    printf 'x' > "$ARCHIVE_DIR"
    run bash "$SUT" karo "新しい便" notice ashigaru1
    [ "$status" -eq 0 ]

    # 見送った事を名乗っている
    echo "$output" | grep -q "切り詰めを見送った"
    # 何通 越えているかを出しており、その数が実際と合っている（61 - 50 = 11）
    local claimed over
    claimed="$(echo "$output" | sed -n 's/.*上限 50 を \([0-9]\+\) 通 越えて.*/\1/p' | head -1)"
    [ -n "$claimed" ]
    over=$(( $(count_in "$INBOX") - 50 ))
    [ "$claimed" -eq "$over" ]

    # 捨ててもおらぬのに「捨てた」と名乗らぬ
    if echo "$output" | grep -q "退避してから落とした"; then return 1; fi

    # 中途半端な退避 file を残さぬ（ARCHIVE_DIR は file のままである）
    [ ! -d "$ARCHIVE_DIR" ]
}
