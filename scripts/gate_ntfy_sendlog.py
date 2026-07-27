#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gate_ntfy_sendlog.py — 「我らの通知が死んでおるか」を送信 log から判ずる薄い判定子 (cmd_1381 段5(b))

★兄弟との違いを先に述べる (二つは別の物を見ておる)★
  ・gate_ntfy_alive.py  = ★engine 側★の自己試験 (logs/ntfy-state.json) を読む = 「engine の通知路」
  ・本 script           = ★shogun 側★の実送信 (logs/ntfy_send.log) を読む   = 「我らが現に撃った矢」
  ⇒ ★engine が緑でも、我らの scripts/ntfy.sh が死んでおれば殿へは届かぬ★。之が第二の口の在る理由じゃ。

★北極星 (cmd_1381 の起源)★= 通知は3ヶ月近く届かず、気づいたのは【偶然 log を掘ったから】である。
  ⇒ ★log は在ったが、読む者が居らなんだ★。本 script は其の【読む者】である。

★★三値を潰さぬ★★ (兄弟と同じ規律。之が本 gate の急所):
  PASS         (rc=0) — 窓の中に ★届いた矢が在り★ 失敗が閾未満
  FAIL         (rc=1) — ★通知が死んでおる★ = 窓の中に事象が在るのに成功が皆無 / 失敗が K 件以上
  UNDETERMINED (rc=2) — ★未検分★ = log が無い/読めぬ/形が違う/★窓の中に事象が無い (沈黙)★/暦が食い違う

★★沈黙を【異常】と呼ばぬ理由 = 家老の下命の字面から意図して外した一点であり、実測に拠る★★
  下命は「直近 N 分に die/000/6/7 が K 件以上 ★or 成功が一度も無い★ → 異常」であった。
  ★然れど本 log 1,096 件の送信間隔を実測すると 中央 13.1 分・p90 86.3 分・p95 280.5 分・最大 7,056 分★。
  ⇒ ★窓が空なのは【平常】であって【異常】ではない★。空窓を FAIL と呼べば、
    ★静かな夜に毎回 鳴る門★ = 「無い」を「届かなんだ」と読む嘘 (差し戻し F-2 と同じ族) になる。
  ⇒ ゆえに ★空窓は UNDETERMINED★。★「成功が一度も無い」は【事象が1件以上在る窓】に限って FAIL とする★。
  ★★但し之は【此の log の性質】であって一般の真ではない (軍師二号 O-5)★★ =
    ★送信間隔が中央 13.1 分・最大 4.9 日 という数は shogun の ntfy_send.log を全数 読んで出した物である★。
    ⇒ ★毎分 撃つ log なら「空窓=異常」が正しい★。★他の log へ本判定を横滑りさせるな★ =
      ★横へ持って行くなら、其の log の間隔を先に測り直せ★。

★★偽陽性の側へ倒しておることも名乗る★★
  ★窓に失敗が1件だけ在り成功が0件でも FAIL を出す★ = 単発の transient も鳴る。
  ⇒ ★之は承知の上の傾け方じゃ★= 本 cmd の起源が「3ヶ月 黙って死んでおった」ゆえ、
    ★鳴り過ぎる側と黙り過ぎる側なら、鳴り過ぎる側へ倒す★。件数は所見に必ず出すゆえ読み手が判じられる。

★答えぬ問い (限界の名乗り)★:
  ・本 script は ★log に書かれた事しか知らぬ★ = ★ntfy.sh を一度も呼んでおらぬ経路の死は見えぬ★
    (例: 呼び手の側が死んでおる時。之は log に何も残らぬゆえ ★沈黙★ として出る)。
  ・★HTTP 2xx は「ntfy.sh が受け取った」までであり「殿の端末が鳴った」ではない★
    (端末側の購読断は本 log からは原理的に見えぬ)。
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as _dt
import hashlib
import io
import os
import re
import sys
import tempfile
import traceback
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOG = REPO_ROOT / "logs" / "ntfy_send.log"

# ── ★閾は撃つ前に置く★ (後から緩めれば、それは数に合わせにいくことである) ──────────────
# WINDOW_MIN=180 の根拠 = ★実測 p90 の送信間隔 86.3 分★。3h 窓なら
#   「系が動いておれば窓に何かが入る」が9割方 成り立ち、且つ ★失敗の束を其の時間内に名指せる★。
WINDOW_MIN = 180.0
# MAX_FAIL=3 の根拠 = ★本 log の非2xx は全期間で 15 件 (全て 500)★ かつ
#   ★3h 窓で失敗が同時に 3 件 積み上がった事は、偽 curl の試験を除けば一度も無い★ (実測)。
MAX_FAIL = 3
# 未来へ振れた刻をどこまで許すか (盤面の時計と log の書き手が食い違う時)。
FUTURE_TOLERANCE_MIN = 5.0

PASS, FAIL, UNDET = 0, 1, 2
_VERDICT = {PASS: "PASS", FAIL: "FAIL", UNDET: "UNDETERMINED"}

# ★行の形★= [時刻] HTTP=… curl_rc=… title=…
#   ★curl_rc を optional にしてあるのは【旧 1,097 行を今も読めるため】★ (実測 1,097/1,097 が解ける)。
#   ★offset も optional★= 旧行は naive・段5(a) 以降の行は +09:00 つき。
# ★cmd_1419 で caller / fp / dup_age を足した★= いずれも optional。
#   ★title は常に最後★ = 題は自由文（空白を含む）ゆえ、後ろに欄を置くと題が食ってしまう。
#   ★optional にした理由★= 旧 1,097 行にはこれらが無い。新旧どちらも同じ規則で読めること。
LINE_RE = re.compile(
    r"^\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?P<off>[+-]\d{2}:?\d{2})?\]"
    r" HTTP=(?P<http>\S+)"
    r"(?: curl_rc=(?P<rc>\S+))?"
    r"(?: caller=(?P<caller>\S+))?"
    r"(?: fp=(?P<fp>\S+))?"
    r"(?: dup_age=(?P<dup_age>\S+))?"
    r" title=(?P<title>.*)$"
)

# curl の rc のうち、名指しできる物 (所見を読む者のため)
_CURL_RC_NAMES = {
    "6": "DNS が引けぬ (CURLE_COULDNT_RESOLVE_HOST)",
    "7": "繋がらぬ (CURLE_COULDNT_CONNECT)",
    "28": "時間切れ (CURLE_OPERATION_TIMEDOUT)",
    "35": "TLS が握れぬ (CURLE_SSL_CONNECT_ERROR)",
}


class Event:
    __slots__ = ("at", "http", "rc", "kind", "naive")

    def __init__(self, at: _dt.datetime, http: str, rc: str | None, kind: str, naive: bool):
        self.at, self.http, self.rc, self.kind, self.naive = at, http, rc, kind, naive

    def label(self) -> str:
        if self.kind == "die":
            name = _CURL_RC_NAMES.get(self.rc or "", "")
            tail = f" = {name}" if name else ""
            return f"curl_rc={self.rc}{tail}"
        return f"HTTP={self.http}"


def classify(http: str, rc: str | None) -> str:
    """★ok / die / reject / shape の四つへ分ける★。

    ★rc が【無い】行の読み方を明示する★= 段5(a) 以前の行には curl_rc が無い。
      旧 code は ★curl が死ぬと 1 行も残らなんだ★ (段4 の commit message が其の事実である) ゆえ、
      ★行が在る = curl は完走しておった★ と読める。★之は【code に基づく推論】であって記録ではない★ —
      ゆえに所見でも「rc 欄なし=旧形式」と名乗る。
    """
    if rc is not None:
        if not re.fullmatch(r"\d+", rc):
            return "shape"
        if rc != "0":
            return "die"
    if re.fullmatch(r"2\d\d", http):
        return "ok"
    return "reject"  # 000 / NONE / 4xx / 5xx / 其の他


def load_testline_hashes(log_path: Path) -> tuple[set[str], str]:
    """★試験由来と名指された行の sha256 を読む (cmd_1400)★ → (hashes, 註記)

    ★何ゆえ sha256 か = 之が silencer にならぬ唯一の造りゆえ★:
      時刻や題や pattern で照合すれば ★将来の本物の失敗まで巻き添えで黙らせる道★ が開く。
      ★行 全体の hash なら 1 byte 違えば当たらぬ★ = 名指しできるのは【既に在る其の行】だけである。
    ★読めぬ・無い時は空集合★ = ★除外は【足す】側の働きゆえ、読めねば何も除かぬのが安全側★。
    """
    side = log_path.with_name(log_path.name.replace(".log", "") + ".testlines.yaml")
    if not side.exists():
        return set(), ""
    try:
        raw = side.read_bytes().decode("utf-8", errors="replace")
    except OSError as e:
        return set(), f" ※ 試験行の名簿が読めぬ ({e}) = 何も除いておらぬ"
    hashes = {m.group(1) for m in re.finditer(r"^\s*-?\s*sha256:\s*([0-9a-f]{64})\s*$", raw, re.M)}
    return hashes, ""


def parse_lines(text: str, local_tz: _dt.tzinfo | None) -> tuple[list[Event], int, int]:
    """→ (事象, 解けなんだ行数, 総行数)。★空行は数に入れぬ★ (末尾改行で1行 増えて見えるのを防ぐ)。

    ★naive な刻 (段5(a) 以前の行) は local_tz を着せて aware へ揃える★ =
      ★之を怠れば naive と aware の比較で TypeError が出る★ — ★拙者は現に此処で落ちた★
      (S7/S20 が judge の例外として捕えた) ⇒ ★受け皿が無ければ「己の crash が通知路の罪」に化ける形★。
      ★着せた事実は Event.naive に残す★ = 呼び手が「盤面の TZ に頼った」ことを判ぜられる。
    """
    events: list[Event] = []
    unparsed = 0
    total = 0
    for raw in text.splitlines():
        if not raw.strip():
            continue
        total += 1
        m = LINE_RE.match(raw)
        if not m:
            unparsed += 1
            continue
        off = m.group("off")
        try:
            at = _dt.datetime.fromisoformat(m.group("ts") + (off or ""))
        except ValueError:
            unparsed += 1
            continue
        if at.tzinfo is None:
            at = at.replace(tzinfo=local_tz)
        kind = classify(m.group("http"), m.group("rc"))
        if kind == "shape":
            unparsed += 1
            continue
        events.append(Event(at, m.group("http"), m.group("rc"), kind, naive=off is None))
    return events, unparsed, total


def judge(log_path: Path, now: _dt.datetime, window_min: float = WINDOW_MIN,
          max_fail: int = MAX_FAIL) -> tuple[int, list[str]]:
    """★三値を返す★。out 行は角括弧札つき (gate_nightly / 番人 が所見へ畳む口)。"""
    out: list[str] = []

    if not log_path.exists():
        out.append(
            f"[NTFY-SEND-UNSEATED] UNDETERMINED: 送信 log が【無い】 ({log_path}) "
            "= ★据わっておらぬ★ (★届かなんだ ではない★)。scripts/ntfy.sh が一度も走っておらぬか "
            "path 違いの疑い ⇒ ★通知路の生死について本 script は何も申せぬ★"
        )
        return UNDET, out

    try:
        blob = log_path.read_bytes()
    except OSError as e:
        out.append(
            f"[NTFY-SEND-SHAPE] UNDETERMINED: log が読めぬ ({e}) "
            "= ★読めぬは「届かなんだ」ではない★ (我らの側の落ち度を通知路の罪にせぬ)"
        )
        return UNDET, out

    # ★★不正 UTF-8 を【落ちる理由】にせぬ★★ (差し戻し F-2 の族を、此処で構造ごと避ける)
    #   ■ ★本物の log の不正 byte = 数が二つ在る。★どちらも上書きせず両方 残す★ (採取時刻つき)★:
    #       ・★2026-07-27 01:1x 実測 = 不正 byte 46 箇所★ (段5(a) 以前の head -c 80 が多byteを切った跡)
    #       ・★2026-07-27 02:0x 実測 = 不正 byte 0 箇所 / U+FFFD の実体 29 個★ (軍師二号も同値)
    #   ■ ★★何ゆえ変わったか = 拙者が焼いた (足軽四号の落ち度・02:0x に自ら特定)★★ =
    #       ★cmd_1400 で harness の 2 行を畳んだ折、log を errors="replace" で読んで write_text で書き戻した★
    #       ⇒ ★46 箇所の壊れた byte 列が 29 個の U+FFFD へ【恒久に】置き換わった★。
    #       ★焼かれる前の複製は残っておらぬ (harness の控えは 01:48 = 既に焼けた後)★。
    #   ■ ⇒ ★★元の byte は復元できぬ = 「後で直す」道は無い★★ (家老 02:03 の下命どおり前提として書く)。
    #       ★失われたのは【既に壊れておった title の末尾】であり、本文や判定欄ではない★ —
    #       ★然れど「証拠を消さぬ」と申しておった当人が消した事実は、消さずに此処へ残す★。
    #   ■ ★然れど本 script が判ずる欄 (時刻/HTTP/curl_rc) は全て ASCII★ = 壊れておるのは常に title の末尾。
    #     ⇒ ★errors="replace" で漉して読み、壊れた行数を所見に名乗る★ =
    #       ★落ちて「通知路 FAIL」に化けるより、読んで数を出す方が正しい★。
    text = blob.decode("utf-8", errors="replace")
    damaged = text.count("�")

    # ★cmd_1400 = 試験由来と名指された行を除く★。★除いた本数は必ず所見へ出す (黙って減らさぬ)★。
    testline_hashes, side_note = load_testline_hashes(log_path)
    excluded = 0
    if testline_hashes:
        keep: list[str] = []
        for line in text.splitlines():
            if hashlib.sha256(line.encode("utf-8")).hexdigest() in testline_hashes:
                excluded += 1
                continue
            keep.append(line)
        text = "\n".join(keep)

    events, unparsed, total = parse_lines(text, now.tzinfo)

    if total == 0:
        out.append(
            f"[NTFY-SEND-UNSEATED] UNDETERMINED: log が【空】 ({log_path}) "
            "= ★一度も撃っておらぬ★ (★届かなんだ ではない★)"
        )
        return UNDET, out

    if not events:
        out.append(
            f"[NTFY-SEND-SHAPE] UNDETERMINED: {total} 行いずれも読めぬ形であった (解けなんだ={unparsed}) "
            "= ★知らぬ形を読んで色を付けるな★ (書き手が形を変えた時、此処が黙って緑になる道を塞ぐ)"
        )
        return UNDET, out

    # ── ★暦の検分 (F-B 型の自己点検 = 盤面のおかげで緑、を作らぬ)★ ──
    #   ★naive な行 (段5(a) 以前) を読む時に限り、盤面が JST である前提に頼っておる★。
    #   ⇒ ★offset つきの行しか窓に無ければ、此の検は要らぬ★ = 段5(a) の値打ちの一つである。
    lo = now - _dt.timedelta(minutes=window_min)
    hi = now + _dt.timedelta(minutes=FUTURE_TOLERANCE_MIN)
    win = [e for e in events if lo < e.at <= hi]

    if any(e.naive for e in win):
        off = now.utcoffset()
        off_h = None if off is None else off.total_seconds() / 3600.0
        if off_h is None or abs(off_h - 9.0) > 1e-9:
            out.append(
                f"[NTFY-SEND-CALENDAR] UNDETERMINED: 窓の中に ★offset 無しの行★ が在るのに "
                f"本 process の local が JST(+0900) でない (offset={off_h}) "
                "= 旧形式の naive 時刻を local と読む前提が崩れておる "
                "⇒ ★9h ずれた齢で偽の色を出しうるゆえ判じぬ★"
            )
            return UNDET, out

    future = [e for e in events if e.at > hi]
    if future:
        newest = max(e.at for e in future)
        ahead = (newest - now).total_seconds() / 60.0
        out.append(
            f"[NTFY-SEND-CALENDAR] UNDETERMINED: log に ★未来の刻★ が在る "
            f"({len(future)} 件・最も先は {ahead:.1f} 分先 = {newest.isoformat()}) "
            "= ★盤面の時計と log の書き手が食い違うておる★ ⇒ 窓を切れぬゆえ判じぬ "
            "(規律(7) = 暦は思い出すな撃って写せ、の破れ口)"
        )
        return UNDET, out

    excl_note = ""
    if excluded or side_note:
        excl_note = (f" ※ ★試験由来として除いた行 {excluded} 本★ (cmd_1400 の名簿 = 行 全体の sha256 照合)"
                     if excluded else "") + side_note
    dmg_note = ""
    if damaged:
        dmg_note = (f" ※ log 中に不正 byte {damaged} 箇所 (段5(a) 以前の多byte切断の跡) "
                    "— 判ずる欄は ASCII ゆえ判定には影響せぬ")
    shape_note = f" / 読めなんだ行 {unparsed}" if unparsed else ""

    newest = max(e.at for e in events)
    age_min = (now - newest).total_seconds() / 60.0

    if not win:
        out.append(
            f"[NTFY-SEND-SILENT] UNDETERMINED: 直近 {window_min:.0f} 分に ★送信そのものが 1 件も無い★ "
            f"(log 全体 {len(events)} 件・最後の送信は {age_min:.1f} 分前 = {newest.isoformat()})"
            f"{shape_note}{dmg_note}{excl_note} — ★沈黙は【死んでおる】の証ではない★ "
            "(実測: 送信間隔は 中央 13.1 分・p95 280.5 分ゆえ、空窓は平常に起こる) "
            "⇒ ★検分できておらぬは緑でも赤でもない★"
        )
        return UNDET, out

    ok = [e for e in win if e.kind == "ok"]
    die = [e for e in win if e.kind == "die"]
    rej = [e for e in win if e.kind == "reject"]
    bad = die + rej
    denom = (f"直近 {window_min:.0f} 分: 成功 {len(ok)} / 失敗 {len(bad)} "
             f"(curl 死 {len(die)}・非2xx {len(rej)}) / 計 {len(win)} 件")
    worst = ", ".join(sorted({e.label() for e in bad}))[:200]

    if not ok:
        out.append(
            f"[NTFY-SEND-DEAD] FAIL: ★窓の中の送信が【一つも届いておらぬ】★ — {denom}。"
            f"内訳={worst}{shape_note}{dmg_note}{excl_note} "
            "⇒ ★殿へ通知は届いておらぬ公算が高い★ "
            "(★但し本 script が見ておるのは ntfy.sh の応答までであり、殿の端末が鳴ったか迄は見ておらぬ★)"
        )
        return FAIL, out

    if len(bad) >= max_fail:
        out.append(
            f"[NTFY-SEND-BURST] FAIL: ★失敗が {len(bad)} 件 (閾 {max_fail} 件) 積み上がっておる★ — {denom}。"
            f"内訳={worst}{shape_note}{dmg_note}{excl_note} "
            "⇒ ★成功も在るゆえ全断ではないが、取りこぼしが現に出ておる★ "
            "(実測: 本 log の非2xx は全期間で 15 件ゆえ、3h に 3 件は平常ではない)"
        )
        return FAIL, out

    out.append(
        f"ok [NTFY-SEND-OK] PASS: ★直近 {age_min:.1f} 分前に現に届いておる★ — {denom}"
        f"{shape_note}{dmg_note}{excl_note}"
    )
    return PASS, out


def run(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="送信 log から通知の生死を判ずる (cmd_1381 段5b)")
    ap.add_argument("--log-file", default=os.environ.get("NTFY_LOG_FILE", str(DEFAULT_LOG)))
    ap.add_argument("--window-min", type=float, default=WINDOW_MIN)
    ap.add_argument("--max-fail", type=int, default=MAX_FAIL)
    ap.add_argument("--now", default=None, help="試験用: ISO8601 (既定は撃って写す=規律(7))")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    # ★暦は思い出すな、撃って写せ (規律(7))★ = 既定は必ず実時刻。--now は試験の口である。
    now = _dt.datetime.now().astimezone()
    if a.now:
        with contextlib.suppress(ValueError):
            d = _dt.datetime.fromisoformat(a.now.replace("Z", "+00:00"))
            now = d if d.tzinfo else d.replace(tzinfo=now.tzinfo)

    # ★受け皿 (差し戻し F-2 の構造側)★= ★本 script 自身の crash は通知路について何も語っておらぬ★
    #   ⇒ rc=1 (届かなんだ) にせず UNDETERMINED へ倒し、★札つきの1行を必ず出す★ (赤いが中身が空、を作らぬ)。
    try:
        rc, out = judge(Path(a.log_file), now, a.window_min, a.max_fail)
    except Exception as e:  # noqa: BLE001 — 受け皿ゆえ広く捕るのが狙いである
        traceback.print_exc()
        rc = UNDET
        out = [
            f"[NTFY-SEND-CRASH] UNDETERMINED: ★本 script 自身が例外で落ちた★ ({type(e).__name__}: {e}) "
            "= ★之は通知路の生死について何も語っておらぬゆえ「届かなんだ」と呼ばぬ★ "
            "(判定子の不具合であり、殿への通知が壊れた証ではない)。traceback は stderr に在る"
        ]
    # ★出口も受け皿の内へ (差し戻し F-3)★= ★flush まで内へ入れねば、失敗は我らの手を離れた後に出る★
    #   (無buffer なら rc=1・buffer なら rc=120 = ★己の死ぬ色を CPython の終了規約に委ねる形★)。
    try:
        for line in out:
            print(line)
        print(f"── [gate-3b ntfy-send] {_VERDICT[rc]} (見た物={a.log_file}) ──")
        sys.stdout.flush()
    except Exception as e:  # noqa: BLE001 — 報せる段の受け皿
        traceback.print_exc()
        print(f"[NTFY-SEND-CRASH] UNDETERMINED: ★所見を刷る段が落ちた★ ({type(e).__name__}: {e}) "
              "= ★通知路の生死について何も語っておらぬ★", file=sys.stderr)
        with contextlib.suppress(Exception):
            sys.stdout = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
        return UNDET
    return rc


# ============================================================================
# selftest — ★牙は「鳴る側」と「鳴らぬ側」を同数 撃つ★
#   (片方だけでは【常に鳴る門】と区別がつかぬ)
# ============================================================================

def selftest() -> int:
    NOW = _dt.datetime.fromisoformat("2026-07-27T06:30:00+09:00")
    fails: list[str] = []
    seen: set[int] = set()

    def line(min_ago: float, http: str = "200", rc: str | None = "0",
             title: str = "試験", offset: bool = True) -> str:
        t = NOW - _dt.timedelta(minutes=min_ago)
        stamp = t.strftime("%Y-%m-%dT%H:%M:%S") + ("+09:00" if offset else "")
        rcs = "" if rc is None else f" curl_rc={rc}"
        return f"[{stamp}] HTTP={http}{rcs} title={title}"

    def check(tid: str, want_rc: int, *, lines=None, raw_bytes=None, write=True,
              needle=None, forbid=None, now=NOW, window=WINDOW_MIN, maxfail=MAX_FAIL):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "ntfy_send.log"
            if write and raw_bytes is not None:
                p.write_bytes(raw_bytes)
            elif write and lines is not None:
                p.write_text("\n".join(lines) + "\n", encoding="utf-8")
            # ★1本の crash で残りの検を殺さぬ★= 例外は其の検の NG として名指し、他は走らせる。
            try:
                rc, out = judge(p, now, window, maxfail)
            except Exception as e:  # noqa: BLE001
                fails.append(f"★NG★ {tid}: judge が例外で落ちた ({type(e).__name__}: {e})")
                return
        body = "\n".join(out)
        seen.add(rc)
        if rc != want_rc:
            fails.append(f"★NG★ {tid}: rc={_VERDICT[rc]} を得たが {_VERDICT[want_rc]} を期待 / out={body}")
            return
        if needle and needle not in body:
            fails.append(f"★NG★ {tid}: 札 {needle} が出ておらぬ / out={body}")
            return
        if forbid and forbid in body:
            fails.append(f"★NG★ {tid}: 出てはならぬ札 {forbid} が出ておる / out={body}")
            return
        print(f"ok {tid} ({_VERDICT[rc]})")

    # ── ★急所★「無い」「沈黙」は【未検分】であって【届かなんだ】ではない ──
    check("S1 log が無い→未検分", UNDET, write=False,
          needle="[NTFY-SEND-UNSEATED]", forbid="[NTFY-SEND-DEAD]")
    check("S2 log が空→未検分", UNDET, lines=[],
          needle="[NTFY-SEND-UNSEATED]", forbid="[NTFY-SEND-DEAD]")
    check("S3 窓の外にしか事象が無い (沈黙)→未検分", UNDET,
          lines=[line(400, "200")], needle="[NTFY-SEND-SILENT]", forbid="[NTFY-SEND-DEAD]")
    check("S4 窓の外の【失敗】だけ→未検分 (古い赤を毎朝鳴らさぬ)", UNDET,
          lines=[line(400, "000", "7")], needle="[NTFY-SEND-SILENT]", forbid="[NTFY-SEND-DEAD]")

    # ── ★鳴らぬ側 (PASS)★ ──
    check("S5 窓に成功が在る→PASS", PASS, lines=[line(10, "200")], needle="[NTFY-SEND-OK]")
    check("S6 成功+失敗2件 (閾未満)→PASS", PASS,
          lines=[line(30, "200"), line(20, "500"), line(10, "500")],
          needle="[NTFY-SEND-OK]", forbid="[NTFY-SEND-BURST]")
    check("S7 旧形式 (curl_rc 欄なし) の 200 も成功と読む→PASS", PASS,
          lines=[line(10, "200", rc=None, offset=False)], needle="[NTFY-SEND-OK]")

    # ── ★鳴る側 (FAIL)★ = 下命の die/000/6/7 を一つずつ撃つ ──
    check("S8 窓に事象は在るが成功0 (HTTP 500)→FAIL", FAIL,
          lines=[line(10, "500")], needle="[NTFY-SEND-DEAD]")
    check("S9 curl が死んだ (rc=7 繋がらぬ)→FAIL", FAIL,
          lines=[line(10, "000", "7")], needle="繋がらぬ")
    check("S10 curl が死んだ (rc=6 DNS)→FAIL", FAIL,
          lines=[line(10, "NONE", "6")], needle="DNS が引けぬ")
    check("S11 HTTP=000 (rc=0 でも 2xx でない)→FAIL", FAIL,
          lines=[line(10, "000", "0")], needle="[NTFY-SEND-DEAD]")
    check("S12 成功は在るが失敗が閾 3 件→FAIL (束)", FAIL,
          lines=[line(40, "200"), line(30, "500"), line(20, "500"), line(10, "500")],
          needle="[NTFY-SEND-BURST]")

    # ── ★境界を撃つ★ (閾は撃つ前に置いた。両側を見る) ──
    check("S13 境界の内 179 分前の成功→PASS", PASS, lines=[line(179, "200")], needle="[NTFY-SEND-OK]")
    check("S14 境界の外 181 分前の成功→未検分 (沈黙)", UNDET,
          lines=[line(181, "200")], needle="[NTFY-SEND-SILENT]")
    check("S15 失敗 2 件は閾未満ゆえ束で鳴らぬ", PASS,
          lines=[line(30, "200"), line(20, "500"), line(15, "500")], forbid="[NTFY-SEND-BURST]")

    # ── ★形が違う / 壊れた byte★ ──
    check("S16 全行が読めぬ形→未検分", UNDET,
          lines=["これは log ではない", "***"], needle="[NTFY-SEND-SHAPE]", forbid="[NTFY-SEND-DEAD]")
    check("S17 不正 UTF-8 が title に在っても判定は通る (本物の log の姿)", PASS,
          raw_bytes=("[" + (NOW - _dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%S")
                     + "+09:00] HTTP=200 curl_rc=0 title=").encode() + b"\xe6\x97\xa5\xe3\x81",
          needle="不正 byte")
    check("S18 curl_rc が数でない→其の行は読めぬ扱い", UNDET,
          lines=[line(10, "200", "abc")], needle="[NTFY-SEND-SHAPE]")

    # ── ★暦 (規律(7) / F-B 型)★ ──
    check("S19 未来の刻が在る→未検分", UNDET,
          lines=[line(-120, "200")], needle="[NTFY-SEND-CALENDAR]")
    check("S20 窓に naive 行が在り local が JST でない→未検分", UNDET,
          lines=[line(10, "200", offset=False)], now=NOW.astimezone(_dt.timezone.utc),
          needle="[NTFY-SEND-CALENDAR]")
    check("S21 窓が offset つき行のみなら local が JST でなくとも判ずる", PASS,
          lines=[line(10, "200", offset=True)], now=NOW.astimezone(_dt.timezone.utc),
          needle="[NTFY-SEND-OK]", forbid="[NTFY-SEND-CALENDAR]")

    # ── ★三値が現に3通り出たか★ (門が定数でないことの直接証明) ──
    if seen != {PASS, FAIL, UNDET}:
        fails.append(f"★NG★ S22: 三値が揃っておらぬ (出た rc={sorted(seen)}) = 二値に潰れておる疑い")
    else:
        print("ok S22 三値 (PASS/FAIL/UNDETERMINED) が現に3通り出た")

    # ── ★run() を selftest の射程へ入れる★ (兄弟 gate の差し戻し F-1 の処方を先に踏む) ──
    #   ★judge() だけを検めれば、run() の既定 now・既定 path・受け皿は一本も縛られておらぬ★。
    def run_capture(argv: list[str]) -> tuple[int, str]:
        buf, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
            rc = run(argv)
        return rc, buf.getvalue()

    def run_check(tid: str, want_rc: int, *, min_ago: float, needle=None):
        """★刻を【実時刻から逆算して】置き、run() を --now 無しで通す★。
        ⇒ ★run() の既定 now が実時刻を撃って写しておらねば、齢が狂うて此の検が落ちる★。
        """
        base = _dt.datetime.now().astimezone()
        t = base - _dt.timedelta(minutes=min_ago)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "ntfy_send.log"
            p.write_text(f"[{t.strftime('%Y-%m-%dT%H:%M:%S%z')[:-2]}:"
                         f"{t.strftime('%z')[-2:]}] HTTP=200 curl_rc=0 title=試験\n", encoding="utf-8")
            rc, body = run_capture(["--log-file", str(p)])
        seen.add(rc)
        if rc != want_rc:
            fails.append(f"★NG★ {tid}: rc={_VERDICT[rc]} を得たが {_VERDICT[want_rc]} を期待 / out={body.strip()}")
            return
        if needle and needle not in body:
            fails.append(f"★NG★ {tid}: 札 {needle} が出ておらぬ / out={body.strip()}")
            return
        print(f"ok {tid} ({_VERDICT[rc]})")

    # ★牙の効き方★= 既定 now が固定日時へ差し替われば、齢が此の二本の【逆側】へ倒れる。
    #   ★境界 (180 分) の両側 2 分に挟んである★ ⇒ 固定値が生き残れるのは実時刻の ±2 分のみ =
    #   ★書いた瞬間だけ当たる literal しか通らぬ★。
    run_check("S23 run() 既定 now: 境界の内 (178 分前)→PASS", PASS, min_ago=178, needle="[NTFY-SEND-OK]")
    run_check("S24 run() 既定 now: 境界の外 (182 分前)→未検分", UNDET, min_ago=182, needle="[NTFY-SEND-SILENT]")

    # ── ★受け皿の検★= 己の crash を「届かなんだ」と出さぬこと ──
    def check_crash_backstop() -> None:
        def boom(*_a, **_k):
            raise RuntimeError("試験が故意に起こした予期せぬ例外")

        g = globals()
        orig = g["judge"]
        g["judge"] = boom
        try:
            with tempfile.TemporaryDirectory() as td:
                p = Path(td) / "ntfy_send.log"
                p.write_text("", encoding="utf-8")
                rc, body = run_capture(["--log-file", str(p)])
        finally:
            g["judge"] = orig
        seen.add(rc)
        if rc != UNDET:
            fails.append(f"★NG★ S25: 判定子が例外で落ちた時 rc={_VERDICT[rc]} を返した "
                         "= ★己の crash を通知路の罪として出しておる★ (期待=UNDETERMINED)")
            return
        if "[NTFY-SEND-CRASH]" not in body:
            fails.append(f"★NG★ S25: 例外時に札が stdout へ出ておらぬ = ★赤いが中身が空★ / out={body.strip()}")
            return
        print("ok S25 判定子自身の crash は未検分 + 札つきで出る (UNDETERMINED)")

    check_crash_backstop()

    # ── ★出口の検★= 刷る段が落ちた時の色 (兄弟 gate の差し戻し F-3 と同型) ──
    def check_stdout_death() -> None:
        class _DeadOut(io.StringIO):
            def write(self, *_a, **_k):
                raise OSError(28, "試験が故意に塞いだ stdout")

            def flush(self):
                raise OSError(28, "試験が故意に塞いだ stdout (flush)")

        base = _dt.datetime.now().astimezone()
        t = base - _dt.timedelta(minutes=5)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "ntfy_send.log"
            p.write_text(f"[{t.isoformat(timespec='seconds')}] HTTP=200 curl_rc=0 title=試験\n",
                         encoding="utf-8")
            err = io.StringIO()
            real_out = sys.stdout
            escaped: Exception | None = None
            rc = UNDET
            try:
                sys.stdout = _DeadOut()
                with contextlib.redirect_stderr(err):
                    rc = run(["--log-file", str(p)])
            except Exception as e:  # noqa: BLE001
                escaped = e
            finally:
                sys.stdout = real_out
        if escaped is not None:
            fails.append(f"★NG★ S26: stdout が死んでおる時、例外が run() の外へ抜けた "
                         f"({type(escaped).__name__}: {escaped}) = ★色が CPython の終了規約任せ★")
            return
        seen.add(rc)
        if rc != UNDET:
            fails.append(f"★NG★ S26: stdout が死んでおる時 rc={_VERDICT[rc]} を返した "
                         "= ★己の出口の不具合を通知路の罪として出しておる★")
            return
        if "[NTFY-SEND-CRASH]" not in err.getvalue():
            fails.append("★NG★ S26: stdout が死んだ時、札が stderr へも出ておらぬ = ★色は安全だが中身が空★")
            return
        print("ok S26 刷る段が落ちても未検分 + 札は stderr へ逃がす (UNDETERMINED)")

    check_stdout_death()

    print(f"── [gate-3b ntfy-send selftest] {len(fails)} 件の NG / 検 26 本 ──")
    for f in fails:
        print(f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(run())
