#!/usr/bin/env python3
"""★牙が【いつ死んだか】を名乗らせる口★ (cmd_1396 系・2026-07-27 六号)

■ ★何故 此の口が要るか (本夜 三度 出た族)★
  2026-07-27 の夜、★「登録した時は PASS であった牙が、今 UNDETERMINED になっておる」★形が三度 出た:
    ・MUT-1355-001   … 他人の commit (7d35e40) が anchor を非一意にした
    ・MUT-1401-G1/G2/G3 … 五号の commit (6486fde) が baseline を赤にした (★己の commit で己の牙を★)
    ・一号の M2      … 家老が表を変え、焼き付けた前提が偽になった
  ★三つとも【誰の咎でもない】★= ★下限も登録も其の時は正しく、動いたのは盤面である★。

■ ★★何が危ういか = 毎朝の門は「UNDETERMINED 3 件」としか申さぬ★★
  ★之は【昨日まで PASS であった 3 件】なのか【元より測れておらぬ 3 件】なのか を分かたぬ★。
  ★前者は退行・後者は未着手★= ★★同じ札の下に、急ぎの物と急がぬ物が混ざる★★
  ⇒ ★読む者は毎朝 同じ数を見て、やがて読まなくなる★ (= 番人が形骸化する入口)。
  ⇒ ★本口は【遷移】を名乗る★= ★「此の牙は 03:52 に PASS を見た。今 UNDETERMINED である」★。

■ ★★何故 己で replay を撃たぬか (実測して決めた)★★
  ★初めに 6 件で 188.58 秒 (04:00:00〜04:03:09) を測り「31.4 秒/件」と書いた★。
  ★★而して其の平均は誤解を招く★★= ★束を分けて測り直したら 20 倍 開いておった (04:07〜04:10 実測)★:
      ・MUT-1401-G1〜G3 (3 件) = 12.95 秒 ⇒ ★4.3 秒/件★
      ・MUT-1392-M13/M14 (2 件) = 176.07 秒 ⇒ ★88.0 秒/件★ (bats が 12 検・process を起こすゆえ)
  ⇒ ★★標本 6 件の平均を 219 件へ伸ばすのは、本夜 我らが咎めてきた「標本 1 で型を名乗るな」の族★★
    = ★ゆえに「1 時間 55 分」とは申さぬ★。★言えるのは幅である★=
    ★混ざり方次第で 219 件は 約 16 分 〜 約 5 時間 20 分★。
  ⇒ ★★而して結論は幅のどちらの端でも変わらぬ★★=
    ★本口は【replay の出力を読む】だけで試験を一度も走らせぬ = 増える負担は 0 秒★
    ⇒ ★16 分の側であっても、0 秒 の方が安い★= ★★見積りの不確かさが結論を揺らさぬことを確かめてから決めた★★。

■ ★本口が答える問いと、答えぬ問い (射程を先に名乗る)★
    答える … ★前に見た判定と今の判定が違うか★ / ★最後に PASS を見た刻は何時か★
    答えぬ … ★其の判定が正しいか★ (判ずるのは replay であって本口ではない)
    答えぬ … ★台帳に載っておらぬ牙のこと★ (点呼は registry_census.py の役)

■ ★初見を退行と呼ばぬ★= ★簿が空の初回は【全て初見】であり、退行 0 と名乗る★
  = ★★「知らぬ」を「悪い」と読ませぬ★★ (本夜 我らが繰り返し据えた区別)。

使い方:
    python3 scripts/gate_mutation_replay.py | tee /tmp/replay.log
    python3 scripts/gate_verdict_drift.py --check /tmp/replay.log   # 遷移を名乗る (退行あれば rc=1)
    python3 scripts/gate_verdict_drift.py --record /tmp/replay.log  # 簿へ書き込む
    python3 scripts/gate_verdict_drift.py --selftest
"""
from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LEDGER = REPO_ROOT / "queue" / "state" / "mutation_verdict_ledger.yaml"

PASS, FAIL, UNDET = "PASS", "FAIL", "UNDETERMINED"

# gate_mutation_replay.py の印字 = f"  {mark} {verdict:12s} {eid}:{tag} {why} [刻 …]"
#   ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (CLAUDE.md 条F)。
#   探し方 = grep -n 'verdict:12s' scripts/gate_mutation_replay.py
#   mark = "ok  " / "★NG★" / "未定 "
# ★mark でなく verdict の語を鍵にする★= ★mark は飾りであり、語は判定そのものゆえ★。
VERDICT_RE = re.compile(
    r"^\s+(?:ok\s+|★NG★\s*|未定\s+)(PASS|FAIL|UNDETERMINED)\s+(\S+?):", re.M)

# ★退行と呼ぶ遷移★= ★測れておった物が、測れなくなった / 折れた★
REGRESSIONS = {
    (PASS, UNDET): "★測れておった牙が【測れなく】なった★ (baseline 赤 / anchor 非一意 / mutate 空振り)",
    (PASS, FAIL): "★牙が【折れた】★ (変異を当てても試験が赤くならぬ)",
}


def now_str() -> str:
    """★刻は必ず機械に押させる★ (家老 03:49 の全軍規)。"""
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def parse_verdicts(text: str) -> dict[str, str]:
    """replay の出力から {entry_id: verdict} を読む。

    ★同じ id が二度 出たら後を採らぬ = 先を採る★:
      ★一度の走行で同じ牙が二度 判定されることは無い★ゆえ、
      ★二度 出たなら【二つの走行を継ぎ足した log】である★=
      ★其の時 後を採れば、古い走行の判定で新しい物を上書きしうる★。
    """
    out: dict[str, str] = {}
    for verdict, eid in VERDICT_RE.findall(text):
        out.setdefault(eid, verdict)
    return out


def load_ledger(path: Path) -> dict:
    import yaml
    if not path.is_file():
        return {}
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return doc.get("entries") or {}


def save_ledger(path: Path, entries: dict) -> None:
    import yaml
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# ★牙の判定の簿★ = gate_verdict_drift.py が書く。★人が手で書く物ではない★。\n"
        "# ★数を焼いた物ではなく【刻を焼いた物】である★ =\n"
        "#   「最後に PASS を見たのは何時か」を持たせ、遷移を名乗れるようにするのが本旨。\n"
        + yaml.safe_dump({"entries": entries}, allow_unicode=True, sort_keys=True),
        encoding="utf-8")


def merge(entries: dict, current: dict[str, str], stamp: str) -> dict:
    """簿へ今の判定を畳み込む。★last_pass_at は PASS を見た時だけ動かす★。"""
    out = {k: dict(v) for k, v in entries.items()}
    for eid, v in current.items():
        rec = out.setdefault(eid, {"first_seen": stamp, "last_pass_at": None})
        rec["verdict"] = v
        rec["last_seen"] = stamp
        if v == PASS:
            rec["last_pass_at"] = stamp
    return out


def diff(entries: dict, current: dict[str, str]) -> dict:
    """前の簿と今の判定を突き合わせ、遷移を四種へ分ける。"""
    regressed, recovered, fresh, vanished = [], [], [], []
    for eid, v in sorted(current.items()):
        prev = entries.get(eid)
        if prev is None or not prev.get("verdict"):
            fresh.append((eid, v))
            continue
        pv = prev["verdict"]
        if pv == v:
            continue
        if (pv, v) in REGRESSIONS:
            regressed.append((eid, pv, v, prev.get("last_pass_at")))
        elif v == PASS:
            recovered.append((eid, pv))
    for eid, rec in sorted(entries.items()):
        if eid not in current:
            vanished.append((eid, rec.get("verdict"), rec.get("last_seen")))
    return {"regressed": regressed, "recovered": recovered,
            "fresh": fresh, "vanished": vanished}


def render(d: dict, current: dict[str, str], ledger_was_empty: bool, stamp: str,
           cmd: str) -> int:
    print(f"[牙の遷移] 採取時刻 = ★{stamp}★ / 撃った command = `{cmd}`")
    print(f"[牙の遷移] 今の走行が判じた牙 = ★{len(current)}★ 件 "
          f"(PASS {sum(1 for v in current.values() if v == PASS)} / "
          f"FAIL {sum(1 for v in current.values() if v == FAIL)} / "
          f"UNDETERMINED {sum(1 for v in current.values() if v == UNDET)})")
    if ledger_was_empty:
        # ★初回に「退行 N 件」と叫べば、以後 誰も本口を信じぬ★
        print("  ★簿が空である = 本走行は【初見】ゆえ、遷移については何も言うておらぬ★"
              " (★『退行 0』ではない = 『未だ比べる物が無い』である★)")
        return 0

    rc = 0
    if d["regressed"]:
        rc = 1
        print(f"\n  ★★退行 {len(d['regressed'])} 件★★ = ★前は測れておった/立っておった牙である★")
        for eid, pv, v, lp in d["regressed"]:
            print(f"    ★NG★ {eid}: {pv} → {v}")
            print(f"           {REGRESSIONS[(pv, v)]}")
            print(f"           ★最後に PASS を見た刻 = {lp or '記録に無し'}★"
                  "  (★之と今の差の間に何が commit されたかを見よ★)")
    else:
        print("\n  退行 = ★0 件★ (前に PASS/測れておった牙は、今も其のまま)")

    if d["recovered"]:
        print(f"\n  ・回復 {len(d['recovered'])} 件 = "
              + ", ".join(f"{e} ({p} → PASS)" for e, p in d["recovered"]))
    if d["fresh"]:
        print(f"\n  ・初見 {len(d['fresh'])} 件 = ★簿に無い牙ゆえ遷移を言えぬ★ = "
              + ", ".join(f"{e}({v})" for e, v in d["fresh"]))
    if d["vanished"]:
        # ★消えたを「直った」と読ませぬ★= 台帳から抜かれた牙も此処に出る
        print(f"\n  ・★今の走行に居らぬ牙 {len(d['vanished'])} 件★ = "
              "★台帳から抜けたか、走行が其処まで及んでおらぬ★ (★どちらかは本口では判ぜぬ★) = "
              + ", ".join(f"{e}(前={v})" for e, v, _s in d["vanished"]))
    return rc


# ---------------------------------------------------------------------------
def selftest() -> int:
    import tempfile
    ok = ng = 0

    def check(name: str, cond: bool) -> None:
        nonlocal ok, ng
        if cond:
            ok += 1
        else:
            ng += 1
            print(f"  ★NG★ {name}")

    # ★実物の印字を写した見本★ (綴りが変われば本口は黙って何も読まなくなるゆえ)
    SAMPLE = (
        "  [盤面] 本 gate は ★作業ツリー★ を読む\n"
        "  ok   PASS         MUT-1401-G1: [疑い:ashigaru5] 変異後 exit 1 (赤) 確認\n"
        "  未定  UNDETERMINED MUT-1392-M13: [疑い:gunshi1] baseline が赤\n"
        "  ★NG★ FAIL         MUT-9999-X: [疑い:karo] 無効化された変異\n"
        "[gate-2] UNDETERMINED: 3 件中 未判定 1 件\n")
    cur = parse_verdicts(SAMPLE)
    check("T1 三種の判定を実物の綴りから読む",
          cur == {"MUT-1401-G1": PASS, "MUT-1392-M13": UNDET, "MUT-9999-X": FAIL})
    # T1b ★偽にして赤★= 綴りを崩せば読めなくなる筈 (= 本口は綴りに依っておる、と自ら示す)
    check("T1b ★偽にして赤★ 判定の語を崩すと読めぬ",
          parse_verdicts(SAMPLE.replace("PASS", "PASSED")) .get("MUT-1401-G1") is None)
    # T1c ★見出し行や締め行を牙と読まぬ★
    check("T1c 締めの [gate-2] 行を牙と読まぬ",
          "UNDETERMINED:" not in cur and len(cur) == 3)

    # T2 ★退行を名乗る★
    entries = {"A": {"verdict": PASS, "last_pass_at": "2026-07-27 03:52:28"}}
    d = diff(entries, {"A": UNDET})
    check("T2 PASS → UNDETERMINED を退行と呼ぶ",
          d["regressed"] == [("A", PASS, UNDET, "2026-07-27 03:52:28")])
    # T2b ★偽にして赤★= 判定が変わらねば退行は出ぬ
    check("T2b ★偽にして赤★ 判定が同じなら退行 0",
          diff(entries, {"A": PASS})["regressed"] == [])
    # T2c ★PASS → FAIL も退行★
    check("T2c PASS → FAIL も退行", len(diff(entries, {"A": FAIL})["regressed"]) == 1)
    # T2d ★★UNDETERMINED → FAIL は退行と呼ばぬ★★
    #   ★元より測れておらなんだ物が測れて赤くなったのは【前進】である★
    und = {"A": {"verdict": UNDET, "last_pass_at": None}}
    check("T2d ★UNDET → FAIL は退行でない★ (測れておらなんだ物が測れた)",
          diff(und, {"A": FAIL})["regressed"] == [])
    check("T2e UNDET → PASS は回復", diff(und, {"A": PASS})["recovered"] == [("A", UNDET)])

    # T3 ★初見を退行と呼ばぬ★
    d3 = diff({}, {"B": UNDET})
    check("T3 簿に無い牙は初見であって退行でない",
          d3["fresh"] == [("B", UNDET)] and d3["regressed"] == [])

    # T4 ★消えた牙を名乗る (黙って消させぬ)★
    d4 = diff({"C": {"verdict": PASS, "last_seen": "x"}}, {})
    check("T4 今の走行に居らぬ牙を名指す", [e for e, _v, _s in d4["vanished"]] == ["C"])

    # T5 ★last_pass_at は PASS の時だけ動く★
    m = merge({}, {"D": PASS}, "T1")
    m = merge(m, {"D": UNDET}, "T2")
    check("T5 PASS を見た刻を保つ (UNDET では上書きせぬ)",
          m["D"]["last_pass_at"] == "T1" and m["D"]["verdict"] == UNDET
          and m["D"]["last_seen"] == "T2")
    # T5b ★偽にして赤★= 再び PASS を見れば刻は進む
    m2 = merge(m, {"D": PASS}, "T3")
    check("T5b ★偽にして赤★ 再び PASS なら刻が進む", m2["D"]["last_pass_at"] == "T3")

    # T6 ★継ぎ足した log では先の判定を採る★
    two = SAMPLE + "  ok   PASS         MUT-1392-M13: [疑い:gunshi1] 後の走行\n"
    check("T6 同じ id が二度 出たら先を採る", parse_verdicts(two)["MUT-1392-M13"] == UNDET)

    # T7 ★簿の往復★ (書いて読んで同じ物が戻るか)
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "l.yaml"
        save_ledger(p, {"E": {"verdict": PASS, "last_pass_at": "z"}})
        check("T7 簿を書いて読み戻せる", load_ledger(p)["E"]["last_pass_at"] == "z")
        check("T7b 簿が無ければ空を返す (★無いは 0 件であって異常ではない★)",
              load_ledger(Path(td) / "nope.yaml") == {})

    # T8 ★rc の約束★= 退行が在れば 1・無ければ 0
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc_reg = render(diff(entries, {"A": UNDET}), {"A": UNDET}, False, "t", "c")
    check("T8 退行が在れば rc=1", rc_reg == 1)
    check("T8b 最後に PASS を見た刻を出力へ書く", "03:52:28" in buf.getvalue())
    buf2 = io.StringIO()
    with contextlib.redirect_stdout(buf2):
        rc_ok = render(diff(entries, {"A": PASS}), {"A": PASS}, False, "t", "c")
    check("T8c 退行が無ければ rc=0", rc_ok == 0)
    # T8d ★初回は退行を叫ばぬ★
    buf3 = io.StringIO()
    with contextlib.redirect_stdout(buf3):
        rc_first = render(diff({}, {"A": UNDET}), {"A": UNDET}, True, "t", "c")
    check("T8d 簿が空の初回は rc=0 かつ『比べる物が無い』と名乗る",
          rc_first == 0 and "未だ比べる物が無い" in buf3.getvalue())

    # T9 ★★0 を報ずる前の canary = 何も読めなんだ log を緑にせぬ★★
    check("T9 判定を 1 件も読めねば空を返す", parse_verdicts("何も無い\n") == {})

    if ng == 0:
        print(f"[gate_verdict_drift selftest] {ok}/{ok} ALL PASS")
        return 0
    print(f"[gate_verdict_drift selftest] FAIL: ok={ok} ng={ng}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--check", metavar="LOG", help="replay の出力 (- で標準入力)")
    ap.add_argument("--record", metavar="LOG", help="読んだ判定を簿へ書き込む")
    ap.add_argument("--ledger", type=Path, default=LEDGER)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    src = a.check or a.record
    if not src:
        ap.error("--check か --record か --selftest のいずれかを指定せよ")
    text = sys.stdin.read() if src == "-" else Path(src).read_text(
        encoding="utf-8", errors="replace")
    current = parse_verdicts(text)
    if not current:
        # ★読めなんだを緑へ倒さぬ★ (本夜の規律)
        print(f"[牙の遷移] ★UNDETERMINED★ = 判定を 1 件も読めなんだ ({src})"
              " = ★replay の出力か、綴りが変わったかを見よ★")
        return 2
    stamp = now_str()
    entries = load_ledger(a.ledger)
    was_empty = not entries
    cmd = f"python3 scripts/gate_verdict_drift.py --{'record' if a.record else 'check'} {src}"
    rc = render(diff(entries, current), current, was_empty, stamp, cmd)
    if a.record:
        save_ledger(a.ledger, merge(entries, current, stamp))
        print(f"[牙の遷移] 簿へ書いた = {a.ledger}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
