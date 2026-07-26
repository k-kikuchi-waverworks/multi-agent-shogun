#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gate_ntfy_alive.py — 毎朝の gate に「通知は生きておるか」を読ませる (cmd_1381 段3)

★北極星★= 通知は3ヶ月近く一度も届かず、我らが気づいたのは【偶然 2.26MB の log を掘ったから】である。
★ゆえに壊れた通知路の故障を、その通知路で報せてはならぬ★ =
  本 gate は ★別実装 (python/bash)・別 process (cron)・別 repo (shogun)★ で名指す。
  engine の ntfy が死んでも、報せる経路は gate_nightly → inbox_write → 家老 = ★engine の通知路を1bitも通らぬ★。

★読む物★= engine の logs/ntfy-state.json (cmd_1381 段2 が上書きで置く。DB は 1bit も触らぬ)。

★★三値を潰さぬ★★ (本 gate の急所):
  PASS          (rc=0) — 直近 24h に自己試験が【届いた】
  FAIL          (rc=1) — 【届かなんだ】= probe.ok=false / 直近 24h に失敗した attempt が在る
  UNDETERMINED  (rc=2) — 【未検分】= 記録が無い・形が違う・読めぬ・古い・暦が食い違う

★「無い」を「届かなんだ」と読めば嘘になる★ =
  設計正本 §4 の実測どおり、initStaleCleanup は process 起動時に 1 度だけ呼ばれ
  `if (watchdogTimer !== null) return;` の guard が在る ⇒ ★HMR では再登録されず、据えた仕掛けが
  1度も走らぬ★ ⇒ ★state file が【生まれぬ】★。之は「通知が壊れた」ではなく「据わっておらぬ」である。
  ★此処を混ぜれば、本設計自身が cmd_1359 (仕掛けは在るが呼ぶ者が居らぬ) の再演を起こす★ (軍師二号)。

★暦は思い出さず撃って写す (規律(7))★ かつ ★盤面で緑にせぬ (軍師一号 F-B)★:
  state file は ★二種の時刻表記を混ぜておる★ — 之は engine 実装の実測である:
    ・probe.lastAt / writtenAt        = localStamp()      = "YYYY-MM-DD HH:MM:SS" (naive・JST)
    ・lastAttemptAt / lastFailure.at  = toISOString()     = "....Z" (UTC)
  ⇒ ★片方の形しか読めぬ parser は 9 時間ずれる★ = 直近の失敗を「古い」と読んで FAIL を落としうる。
  ⇒ 双方を読む。かつ ★naive を local として読む以上、local が JST でなければ其の読みは成り立たぬ★ ゆえ
    ★TZ が +0900 でない時は緑と呼ばず UNDETERMINED を出す★ (cron の TZ が変われば偽 PASS が出る側の穴)。
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as _dt
import io
import json
import os
import sys
import tempfile
import traceback
from pathlib import Path

DEFAULT_ENGINE_ROOT = "/mnt/c/Users/k-kikuchi/development/ai-automate-engine"
STATE_REL = "logs/ntfy-state.json"
KNOWN_SCHEMA = "ntfy-state/1"
# ★閾を撃つ前に置く★ (後から緩めれば、それは合わせにいくことである)。
# 24h の根拠 = canary は ★local 日付が変われば最初の tick で撃つ★ 造りゆえ、dev server が
# 1 日のうち僅かでも起きておれば其の日に 1 発出る。gate は毎朝 06:30 ゆえ、
# 「server が丸1日 起きなんだ」時にのみ 24h を越える = ★越えたら名指したい当の事象そのもの★。
FRESH_HOURS = 24.0
STALLED_HOURS = 48.0  # 之を越えたら「自己試験が止まっておる」と言葉を強める (判定は同じ UNDETERMINED)

PASS, FAIL, UNDET = 0, 1, 2
_VERDICT = {PASS: "PASS", FAIL: "FAIL", UNDET: "UNDETERMINED"}


def parse_stamp(s: str, now: _dt.datetime) -> _dt.datetime | None:
    """★二種の表記を両方読む★ (片方だけ読む parser は 9h ずれる = 上記 docstring の実測)。

    ・"...Z" / offset つき → aware として読み、now の tzinfo へ揃える
    ・naive ("YYYY-MM-DD HH:MM:SS") → ★local (=now と同じ tz)★ として読む
    """
    if not isinstance(s, str) or not s.strip():
        return None
    t = s.strip().replace("Z", "+00:00")
    try:
        d = _dt.datetime.fromisoformat(t)
    except ValueError:
        try:
            d = _dt.datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=now.tzinfo)
    return d


def age_hours(stamp: str, now: _dt.datetime) -> float | None:
    d = parse_stamp(stamp, now)
    if d is None:
        return None
    return (now - d).total_seconds() / 3600.0


def local_utc_offset_hours(now: _dt.datetime) -> float | None:
    off = now.utcoffset()
    return None if off is None else off.total_seconds() / 3600.0


def judge(state_path: Path, engine_root: Path, now: _dt.datetime) -> tuple[int, list[str]]:
    """★三値を返す★。out 行は角括弧札つき (gate_nightly が所見へ畳む口)。"""
    out: list[str] = []

    # ── 暦の検分 (F-B 型の自己点検 = 盤面のおかげで緑、を作らぬ) ──
    off = local_utc_offset_hours(now)
    if off is None or abs(off - 9.0) > 1e-9:
        out.append(
            f"[NTFY-CALENDAR] UNDETERMINED: 本 process の local が JST(+0900) でない (offset={off}) "
            "= state の naive 時刻 (probe.lastAt) を local と読む前提が崩れておる "
            "⇒ ★9h ずれた齢で偽 PASS を出しうるゆえ緑と呼ばぬ★"
        )
        return UNDET, out

    # ── 記録が在るか ──
    if not engine_root.is_dir():
        out.append(
            f"[NTFY-UNSEATED] UNDETERMINED: engine repo が見えぬ ({engine_root}) "
            "= 通知路の生死を検分できておらぬ。★検分できておらぬは緑ではない★ "
            "(path 違い / disk 喪失 / clone 未実施の疑い)"
        )
        return UNDET, out

    if not state_path.exists():
        out.append(
            f"[NTFY-UNSEATED] UNDETERMINED: {STATE_REL} が【無い】 = ★据わっておらぬ★ "
            "(★届かなんだ ではない★)。cmd_1381 段2/2b は commit 済だが "
            "initStaleCleanup は process 起動時 1 度だけ・watchdogTimer guard 在りゆえ "
            "★HMR では再登録されず、殿が dev server を起こし直すまで 1 度も走らぬ★ "
            "⇒ 解錠条件=★殿が engine dev server を再起動なされること★ (それで此の行は消える)"
        )
        return UNDET, out

    try:
        raw = state_path.read_text(encoding="utf-8")
    except OSError as e:
        out.append(f"[NTFY-SHAPE] UNDETERMINED: {STATE_REL} が読めぬ ({e}) = 記録の不能は「届かなんだ」ではない")
        return UNDET, out
    except ValueError as e:
        # ★cmd_1381 差し戻し F-2 (軍師一号)★= ★UnicodeDecodeError は ValueError の子であって
        #   OSError の子ではない★ ⇒ 旧版は素通り → traceback → rc=1 → gate_nightly が
        #   ★「殿への通知路=FAIL」= 通知路に無い罪を着せた★ (実測: 先頭 byte 0xff で再現)。
        #   ★我らの側の落ち度 (読めぬ byte 列) を、通知路の罪にせぬ★ ゆえ未検分へ倒す。
        out.append(
            f"[NTFY-SHAPE] UNDETERMINED: {STATE_REL} の byte 列が UTF-8 として読めぬ "
            f"({type(e).__name__}: {e}) = ★読めぬは「届かなんだ」ではない★ "
            "(書き手の encoding 違い / 書込中の断片 / file 破損の疑い)"
        )
        return UNDET, out

    try:
        st = json.loads(raw)
        if not isinstance(st, dict):
            raise ValueError("top-level が object でない")
    except (json.JSONDecodeError, ValueError) as e:
        out.append(
            f"[NTFY-SHAPE] UNDETERMINED: {STATE_REL} が JSON として壊れておる ({e}) "
            "= ★壊れた記録を『届かなんだ』と読めば、通知路に無い罪を着せる★"
        )
        return UNDET, out

    schema = st.get("schema")
    if schema != KNOWN_SCHEMA:
        out.append(
            f"[NTFY-SHAPE] UNDETERMINED: schema が知らぬ形 (見た値={schema!r} / 期待={KNOWN_SCHEMA!r}) "
            "= ★知らぬ形を読んで色を付けるな★ (engine 側が形を変えた時、此処が黙って緑になる道を塞ぐ)"
        )
        return UNDET, out

    probe = st.get("probe")
    if not isinstance(probe, dict):
        out.append("[NTFY-SHAPE] UNDETERMINED: probe 節が無い = 自己試験の結果を読む口が無い")
        return UNDET, out

    attempts = st.get("attempts")
    successes = st.get("successes")
    # ★分母を必ず併記する★ = 分母無しでは「成功0件」を【壊れておる】とも【まだ試しておらぬ】とも読めぬ。
    denom = f"実通知 {successes}/{attempts} 件成功"

    ok = probe.get("ok")
    last_at = probe.get("lastAt")

    # ── 実通知の失敗を先に見る (自己試験が緑でも、殿宛の実通知が落ちておれば赤である) ──
    lf = st.get("lastFailure")
    if isinstance(lf, dict) and isinstance(lf.get("at"), str):
        lf_age = age_hours(lf["at"], now)
        if lf_age is None:
            out.append(
                f"[NTFY-SHAPE] UNDETERMINED: lastFailure.at が読めぬ表記 ({lf['at']!r}) "
                "= 失敗の新旧を判じられぬ"
            )
            return UNDET, out
        if lf_age <= FRESH_HOURS:
            out.append(
                f"[NTFY-DEAD] FAIL: ★直近 {lf_age:.1f}h に実通知が届かなんだ★ "
                f"(kind={lf.get('kind')} status={lf.get('status')} reason={lf.get('reason')!r} at={lf['at']}) "
                f"— {denom}。★殿へ届いておらぬ恐れが在る★"
            )
            return FAIL, out

    # ── 自己試験 (canary) ──
    if ok is None or last_at is None:
        out.append(
            f"[NTFY-UNSEATED] UNDETERMINED: 自己試験が【一度も走っておらぬ】 "
            f"(probe.ok={ok!r} probe.lastAt={last_at!r} / {denom}) "
            "= ★未検分は緑ではない★。dev server が起きておれば 1 日 1 回 撃つ造りゆえ、"
            "続くなら ★tick そのものが呼ばれておらぬ★ 疑い (cmd_1359 の族)"
        )
        return UNDET, out

    age = age_hours(last_at, now)
    if age is None:
        out.append(f"[NTFY-SHAPE] UNDETERMINED: probe.lastAt が読めぬ表記 ({last_at!r}) = 齢を判じられぬ")
        return UNDET, out

    if ok is False:
        out.append(
            f"[NTFY-DEAD] FAIL: ★自己試験が通らなんだ★ "
            f"(kind={probe.get('kind')} reason={probe.get('reason')!r} at={last_at} 齢 {age:.1f}h) "
            f"— {denom}。★通知路が壊れておる = 殿へ届かぬ★"
        )
        return FAIL, out

    if ok is not True:
        out.append(f"[NTFY-SHAPE] UNDETERMINED: probe.ok が三値の外 ({ok!r}) = 読み方を決められぬ")
        return UNDET, out

    if age > STALLED_HOURS:
        out.append(
            f"[NTFY-STALE] UNDETERMINED: 自己試験が ★{age:.1f}h 前で止まっておる★ (>{STALLED_HOURS:.0f}h) "
            f"(最後の結果は「届いた」だが古い / {denom}) "
            "= ★昔届いたことは、今 生きておることの証にならぬ★。dev server 停止か tick 不在の疑い"
        )
        return UNDET, out

    if age > FRESH_HOURS:
        out.append(
            f"[NTFY-STALE] UNDETERMINED: 自己試験が {age:.1f}h 前 (>{FRESH_HOURS:.0f}h) = ★1 日以上 撃っておらぬ★ "
            f"(最後の結果は「届いた」/ {denom}) = 検分できておらぬは緑ではない"
        )
        return UNDET, out

    nonascii = probe.get("titleWasNonAscii")
    warn = ""
    if nonascii is not True:
        # ★MUT-2 の族★= ASCII 題で試験すれば cmd_1369d 型 (和文 title の header throw) を素通りする。
        warn = " ★但し titleWasNonAscii が真でない = 和文で試しておらぬ疑い (cmd_1369d 型を捕えられぬ)★"
    out.append(
        f"ok [NTFY-OK] PASS: 自己試験は {age:.1f}h 前に ★届いた★ "
        f"(往復 {probe.get('roundTripMs')}ms topic=…{probe.get('topicSuffix')} / {denom}){warn}"
    )
    return PASS, out


def run(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="通知路の生死を毎朝読む (cmd_1381 段3)")
    ap.add_argument("--engine-root", default=os.environ.get("GATE_ENGINE_ROOT", DEFAULT_ENGINE_ROOT))
    ap.add_argument("--state-file", default=None, help="既定は <engine-root>/logs/ntfy-state.json")
    ap.add_argument("--now", default=None, help="試験用: 'YYYY-MM-DD HH:MM:SS' (既定は撃って写す=規律(7))")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    # ★暦は思い出すな、撃って写せ★ = 既定は必ず実時刻。--now は試験の口である。
    now = _dt.datetime.now().astimezone()
    if a.now:
        now = parse_stamp(a.now, now) or now

    engine_root = Path(a.engine_root)
    state_path = Path(a.state_file) if a.state_file else engine_root / STATE_REL
    # ★F-2 の族を構造で塞ぐ★= 個々の例外を潰すだけでは、次の未知の例外で同じ嘘が出る。
    #   ★本 gate 自身の crash は、通知路について何一つ語っておらぬ★ ⇒ rc=1 (届かなんだ) にせず未検分へ。
    #   ★併せて【赤いが中身が空】も塞ぐ★= 札つきの1行を stdout へ出す
    #   (gate_nightly の所見 grep は札で拾う造りゆえ、traceback だけでは家老に何も届かなんだ)。
    #   ★但し黙って飲み込まぬ★= traceback は stderr へ丸ごと残す。
    try:
        rc, out = judge(state_path, engine_root, now)
    except Exception as e:  # noqa: BLE001 — 受け皿ゆえ広く捕るのが狙いである
        traceback.print_exc()
        rc = UNDET
        out = [
            f"[NTFY-CRASH] UNDETERMINED: ★本 gate 自身が例外で落ちた★ ({type(e).__name__}: {e}) "
            "= ★之は通知路の生死について何も語っておらぬゆえ「届かなんだ」と呼ばぬ★ "
            "(番人の不具合であり、殿への通知が壊れた証ではない)。traceback は stderr に在る"
        ]
    for line in out:
        print(line)
    print(f"── [gate-3 ntfy] {_VERDICT[rc]} (見た物={state_path}) ──")
    return rc


# ============================================================================
# selftest — ★牙は「鳴る側」と「鳴らぬ側」を同数 撃つ★
#   (片方だけでは【常に鳴る門】と区別がつかぬ = 本日 全軍で積んだ作法)
# ============================================================================

def _state(**over) -> dict:
    st = {
        "schema": KNOWN_SCHEMA,
        "attempts": 3,
        "successes": 3,
        "lastAttemptAt": None,
        "lastSuccessAt": None,
        "lastFailure": None,
        "probe": {
            "lastAt": None, "ok": None, "kind": None, "reason": None,
            "topicSuffix": "-selftest", "roundTripMs": 412, "titleWasNonAscii": True,
        },
        "probeLastDate": None,
        "writtenAt": None,
    }
    probe_over = over.pop("probe", None)
    st.update(over)
    if probe_over:
        st["probe"].update(probe_over)
    return st


def selftest() -> int:
    NOW = _dt.datetime.fromisoformat("2026-07-27 06:30:00+09:00")
    jst = NOW.tzinfo

    def local(hours_ago: float) -> str:
        return (NOW - _dt.timedelta(hours=hours_ago)).strftime("%Y-%m-%d %H:%M:%S")

    def utciso(hours_ago: float) -> str:
        return (NOW - _dt.timedelta(hours=hours_ago)).astimezone(_dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.000Z")

    fails: list[str] = []
    seen: set[int] = set()

    def check(tid: str, want_rc: int, *, state=None, write=True, needle=None,
              now=NOW, root_exists=True, raw=None, raw_bytes=None, forbid=None):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "engine"
            if root_exists:
                (root / "logs").mkdir(parents=True)
            sp = root / STATE_REL
            if write and raw_bytes is not None:
                sp.write_bytes(raw_bytes)
            elif write and raw is not None:
                sp.write_text(raw, encoding="utf-8")
            elif write and state is not None:
                sp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
            # ★1本の crash で残りの検を殺さぬ★= 素で呼べば例外が selftest 丸ごとを畳み、
            #   ★続く検が一本も走っておらぬのに「走って落ちた」ように見える★
            #   (拙者は MUT-1381-105 を撃って現に此れを踏んだ = 台帳の牙が試験の穴を暴いた形)。
            #   ⇒ ★例外は【其の検の NG】として名指し、他の検は走らせる★。
            try:
                rc, out = judge(sp, root, now)
            except Exception as e:  # noqa: BLE001 — 検の隔離が狙いである
                fails.append(f"★NG★ {tid}: judge が例外で落ちた ({type(e).__name__}: {e})")
                return
        body = "\n".join(out)
        seen.add(rc)
        if rc != want_rc:
            fails.append(f"★NG★ {tid}: rc={_VERDICT[rc]} を得たが {_VERDICT[want_rc]} を期待 / out={body}")
            return
        if needle and needle not in body:
            fails.append(f"★NG★ {tid}: 札 {needle} が出ておらぬ / out={body}")
        if forbid and forbid in body:
            fails.append(f"★NG★ {tid}: 出てはならぬ札 {forbid} が出ておる / out={body}")
        print(f"ok {tid} ({_VERDICT[rc]})")

    # ── ★急所★ 「無い」は【未検分】であって【届かなんだ】ではない ──
    check("T1 state file が無い→未検分", UNDET, write=False,
          needle="[NTFY-UNSEATED]", forbid="[NTFY-DEAD]")
    check("T2 engine repo が見えぬ→未検分", UNDET, write=False, root_exists=False,
          needle="[NTFY-UNSEATED]", forbid="[NTFY-DEAD]")

    # ── 届いた (PASS) ──
    check("T3 直近に届いた→PASS", PASS,
          state=_state(probe={"ok": True, "lastAt": local(6)}), needle="[NTFY-OK]")

    # ── 届かなんだ (FAIL) ──
    check("T4 自己試験が通らなんだ→FAIL", FAIL,
          state=_state(probe={"ok": False, "lastAt": local(1), "kind": "rejected", "reason": "HTTP 500"}),
          needle="[NTFY-DEAD]")
    check("T5 実通知が直近に失敗 (probe は緑)→FAIL", FAIL,
          state=_state(probe={"ok": True, "lastAt": local(2)},
                       lastFailure={"kind": "threw", "reason": "ByteString", "status": None, "at": utciso(3)}),
          needle="[NTFY-DEAD]")
    check("T6 NTFY_TOPIC 未設定も赤 (切ってあるを緑にせぬ)", FAIL,
          state=_state(probe={"ok": False, "lastAt": local(1), "kind": "skipped",
                              "reason": "NTFY_TOPIC 未設定 = 通知は原理的に届かぬ"}),
          needle="[NTFY-DEAD]")

    # ── 未検分 (UNDETERMINED) の各面 ──
    check("T7 一度も撃っておらぬ→未検分", UNDET,
          state=_state(probe={"ok": None, "lastAt": None}), needle="[NTFY-UNSEATED]", forbid="[NTFY-DEAD]")
    check("T8 30h 前で古い→未検分 (緑にせぬ)", UNDET,
          state=_state(probe={"ok": True, "lastAt": local(30)}), needle="[NTFY-STALE]")
    check("T9 60h 前→未検分 (止まっておる)", UNDET,
          state=_state(probe={"ok": True, "lastAt": local(60)}), needle="止まっておる")
    check("T10 JSON が壊れておる→未検分", UNDET, raw="{壊れ", needle="[NTFY-SHAPE]", forbid="[NTFY-DEAD]")
    check("T11 schema が知らぬ形→未検分", UNDET,
          state=_state(schema="ntfy-state/2"), needle="[NTFY-SHAPE]")
    check("T12 probe 節が無い→未検分", UNDET,
          state={"schema": KNOWN_SCHEMA, "attempts": 0, "successes": 0}, needle="[NTFY-SHAPE]")
    check("T13 probe.ok が三値の外→未検分", UNDET,
          state=_state(probe={"ok": "yes", "lastAt": local(1)}), needle="[NTFY-SHAPE]")

    # ── ★境界を撃つ★ (閾は撃つ前に置いた。境界の両側を見る) ──
    check("T14 23.9h→PASS (境界の内)", PASS,
          state=_state(probe={"ok": True, "lastAt": local(23.9)}), needle="[NTFY-OK]")
    check("T15 24.1h→未検分 (境界の外)", UNDET,
          state=_state(probe={"ok": True, "lastAt": local(24.1)}), needle="[NTFY-STALE]")
    check("T16 実失敗が 25h 前なら赤に倒さぬ (古い赤を毎朝鳴らさぬ)", PASS,
          state=_state(probe={"ok": True, "lastAt": local(3)},
                       lastFailure={"kind": "threw", "reason": "old", "status": None, "at": utciso(25)}),
          needle="[NTFY-OK]", forbid="[NTFY-DEAD]")

    # ── ★二種の時刻表記★ = 片方の形しか読めぬ parser は 9h ずれる (engine 実測) ──
    check("T17 lastFailure が ISO-UTC 表記でも齢を正しく読む", FAIL,
          state=_state(probe={"ok": True, "lastAt": local(1)},
                       lastFailure={"kind": "rejected", "reason": "r", "status": 500, "at": utciso(23)}),
          needle="[NTFY-DEAD]")
    check("T18 ISO-UTC の 25h 前は古い扱い (9h ずれておれば此処が赤くなる)", PASS,
          state=_state(probe={"ok": True, "lastAt": local(1)},
                       lastFailure={"kind": "rejected", "reason": "r", "status": 500, "at": utciso(25)}),
          forbid="[NTFY-DEAD]")

    # ── ★盤面で緑にせぬ (F-B 型)★ = local が JST でなければ緑と呼ばぬ ──
    check("T19 local が JST でない→未検分", UNDET,
          state=_state(probe={"ok": True, "lastAt": local(1)}),
          now=NOW.astimezone(_dt.timezone.utc), needle="[NTFY-CALENDAR]")

    # ── ★三値が現に3通り出たか★ (門が定数でないことの直接証明) ──
    if seen != {PASS, FAIL, UNDET}:
        fails.append(f"★NG★ T20: 三値が揃っておらぬ (出た rc={sorted(seen)}) = 二値に潰れておる疑い")
    else:
        print("ok T20 三値 (PASS/FAIL/UNDETERMINED) が現に3通り出た")

    # ── ★盤面の暦が健全か★ ────────────────────────────────────────────────
    # ★★名を正した (cmd_1381 差し戻し F-1・軍師一号)★★=
    #   旧名は「既定の now が実時刻であることの検」と名乗っておったが ★偽であった★:
    #   此処は selftest 自身が datetime.now() を呼んでおるだけゆえ ★検めておるのは
    #   CPython と system clock (=盤面) であり、production の run() ではない★。
    #   ★軍師の変異 GX-A1 (run() の now を固定日時へ) は本検を素通りした = 真空 PASS★
    #   (拙者も再現した: 2020 固定でも 0 NG、しかも本行は実時刻を印字し続けた)。
    #   ⇒ ★production の側は T23/T24 が run() を実際に通して縛る★。本検は盤面の検として残す。
    real = _dt.datetime.now().astimezone()
    if real.tzinfo is None or real.year < 2026:
        fails.append(f"★NG★ T21: 盤面の時計が壊れておる (tz 無し か 2026 未満: {real})")
    else:
        print(f"ok T21 盤面の時計は健全 ({real.strftime('%Y-%m-%d %H:%M:%S %z')}) "
              "— ★之は盤面の検であり run() の検ではない (production は T23/T24)★")

    # ── ★読めぬ byte 列は【未検分】★ (差し戻し F-2・軍師一号の変異 GX-A2 相当) ──
    #   ★UnicodeDecodeError は ValueError の子 = except OSError を素通りしておった★。
    check("T22 不正 UTF-8 の state→未検分 (我らの落ち度を通知路の罪にせぬ)", UNDET,
          raw_bytes=b'\xff\xfe{"schema":"ntfy-state/1"}',
          needle="[NTFY-SHAPE]", forbid="[NTFY-DEAD]")

    # ── ★run() を selftest の射程へ入れる★ (差し戻し F-1 の処方) ────────────────
    #   ★旧 selftest は judge() のみを呼び run() を一度も通らなんだ★ =
    #   run() の中身 (既定 now・受け皿・state path の既定) は 21 本 いずれの射程にも無かった。
    def run_capture(argv: list[str]) -> tuple[int, str]:
        buf, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
            rc = run(argv)
        return rc, buf.getvalue()

    def run_check(tid: str, want_rc: int, *, hours_ago: float, needle=None, forbid=None):
        """★state の刻を【実時刻から逆算して】置き、run() を --now 無しで通す★。
        ⇒ run() の既定 now が実時刻を撃って写しておらねば齢が狂い、此の検が落ちる。
        """
        base = _dt.datetime.now().astimezone()
        stamp = (base - _dt.timedelta(hours=hours_ago)).strftime("%Y-%m-%d %H:%M:%S")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "engine"
            (root / "logs").mkdir(parents=True)
            (root / STATE_REL).write_text(
                json.dumps(_state(probe={"ok": True, "lastAt": stamp}), ensure_ascii=False),
                encoding="utf-8")
            rc, body = run_capture(["--engine-root", str(root)])
        seen.add(rc)
        if rc != want_rc:
            fails.append(
                f"★NG★ {tid}: rc={_VERDICT[rc]} を得たが {_VERDICT[want_rc]} を期待 / out={body.strip()}")
            return
        if needle and needle not in body:
            fails.append(f"★NG★ {tid}: 札 {needle} が出ておらぬ / out={body.strip()}")
            return
        if forbid and forbid in body:
            fails.append(f"★NG★ {tid}: 出てはならぬ札 {forbid} が出ておる / out={body.strip()}")
            return
        print(f"ok {tid} ({_VERDICT[rc]})")

    # ★牙の効き方★= run() の既定 now が固定日時へ差し替わると、齢が此の二本の【逆側】へ倒れる。
    #   ★境界 (FRESH_HOURS=24h) の両側 0.02h (=72秒) に挟んである★ ⇒
    #   固定値 C が生き残れるのは ★|C - 実時刻| < 72秒★ の時のみ =
    #   ★書いた瞬間だけ当たる literal しか通らぬ = 翌日には必ず落ちる★。
    #   ★答えぬ問い (名乗っておく)★= 「実時刻を撃つ別の実装」に差し替えられた時は通る
    #   (之は狙いどおり = 求めておるのは【撃って写す】ことであり datetime.now() という綴りではない)。
    #   ★盤面依存★= local が JST でない機械では T24 が [NTFY-CALENDAR] で UNDETERMINED になり
    #   ★黙って緑にならず NG として鳴る★ (本 gate は JST 前提を自ら宣言しておる = T19)。
    run_check("T23 run() 既定 now: 境界の内 (23.98h 前)→PASS", PASS,
              hours_ago=23.98, needle="[NTFY-OK]")
    run_check("T24 run() 既定 now: 境界の外 (24.02h 前)→未検分", UNDET,
              hours_ago=24.02, needle="[NTFY-STALE]")

    # ── ★受け皿の検★= 番人自身の crash を「届かなんだ」と出さぬこと (差し戻し F-2 の構造側) ──
    def check_crash_backstop() -> None:
        def boom(*_a, **_k):
            raise RuntimeError("試験が故意に起こした予期せぬ例外")

        g = globals()
        orig = g["judge"]
        g["judge"] = boom
        try:
            with tempfile.TemporaryDirectory() as td:
                root = Path(td) / "engine"
                (root / "logs").mkdir(parents=True)
                rc, body = run_capture(["--engine-root", str(root)])
        finally:
            g["judge"] = orig
        seen.add(rc)
        if rc != UNDET:
            fails.append(
                f"★NG★ T25: 番人が例外で落ちた時 rc={_VERDICT[rc]} を返した = "
                "★己の crash を通知路の罪として出しておる★ (期待=UNDETERMINED)")
            return
        if "[NTFY-CRASH]" not in body:
            fails.append(
                f"★NG★ T25: 例外時に札 [NTFY-CRASH] が stdout へ出ておらぬ = "
                f"★赤いが中身が空★ (gate_nightly の所見に何も載らぬ) / out={body.strip()}")
            return
        print("ok T25 番人自身の crash は未検分 + 札つきで出る (UNDETERMINED)")

    check_crash_backstop()

    print(f"── [gate-3 ntfy selftest] {len(fails)} 件の NG / 検 25 本 ──")
    for f in fails:
        print(f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(run())
