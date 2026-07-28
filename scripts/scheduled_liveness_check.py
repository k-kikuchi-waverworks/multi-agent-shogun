#!/usr/bin/env python3
"""定時実行 7 本が「現に終わったか」を検める (cmd_1465・足軽五号)。

なぜ必要か
----------
毎朝のチェック (gate_nightly) は、家老へ知らせる口を 1 箇所しか持っていません。
その口は全部の段が終わった後で、しかも非 PASS の時だけ鳴ります。
そのため「全部 緑で終わった」と「途中で死んだ」が、どちらも 0 通で同じ顔になります。
実測 (cmd_1465) = 途中で殺すと log に残るのは「開始」の 1 行だけで、警告は 1 通も出ません。

同じ形は毎朝のチェック 1 本の話ではありません。
軍師一号が cmd_1439 で数えた定時実行 7 本のうち、落ちて誰かが気づく形なのは 2 本だけでした。
現に AituberDvcGc は 73 日 止まっており、誰も気づいていません。

「走った証」と「終わった証」は別物です。
  ・log の更新時刻   = 「誰かが何か書いた」しか言えません (途中で死んでも更新されます)
  ・開始の印だけある = 「始まった」までしか言えません
  ・終わりの印がある = これだけが「終わった」と言えます

何を返すか
----------
7 本それぞれを 4 つに分けます:
  OK       … 終わった証があり、期限内
  STALE    … 終わった証はあるが古い            ← 鳴らす
  MISSING  … 終わった証を書く仕掛けが無い      ← 鳴らす (ただし下記の「一度だけ」)
  SKIPPED  … 自分で「見送った」と名乗っている  ← 鳴らさない

SKIPPED を最初から持たせている理由
将来 gate_nightly に重なり止めの錠を掛けると、見送った日は終了の印が出ません。
その時この検めは「途中で死んだ」と読んで鳴ります = 守りが別の守りを誤らせる形です。
そこで「見送った」と「死んだ」を分ける印を、錠より先に決めておきます。
見送る側は下の SKIP_PAT の形で log へ 1 行 書けば、この検めは鳴りません。

MISSING を「一度だけ」鳴らす理由 (家老の推しは「鳴る」側。その上での決め方)
MISSING は人が直すまで消えない状態です。毎回 鳴らせば常に赤い検知になり、
読む者はやがて無視します = 検知そのものが死にます (この repo が繰り返し踏んできた形)。
そこで、鳴らすが、同じ顔ぶれの間は 1 度だけにします。顔ぶれが変われば
(新しい 1 本が証を失えば) それは新しい知らせなので、また鳴ります。
log へは毎回 必ず出します。

この検めが塞げていない所 (先に名乗ります)
このスクリプトは 15 分毎の監視スクリプト (stall_watchdog_scan) に相乗りします。
その監視スクリプト自身が死ねば、この検めも一緒に死にます。監視スクリプトの死に
気づく者は今 居ません。新しい cron を足しても、今度はその cron が黙って死ぬ物に
なるだけで、段が 1 つ増えるにすぎません。
塞げないことを、この稿とここの両方へ書いておきます。塞いだ顔をしないためです。
"""
import argparse
import datetime
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGS_DIR = REPO_ROOT / "logs"

# 自分で「見送った」と名乗る印 (理由は上記)。今はまだこれを書く者が居ない = 将来の約束事。
SKIP_PAT = r"\[(?:gate_nightly|stall_watchdog|idle_revive)\] 見送り"

# 7 本の定義。出所 = plans/cmd_1439_silent_death.md (軍師一号) と crontab の現物。
#   period_min  … 走る間隔 (分)
#   grace_min   … 遅れを許す幅。走行そのものに掛かる時間を含める
#                 (毎朝のチェックは現に 3 時間 掛かる日がある = cmd_1465 実測)
#   end_pat     … 終わりの印 (log の中)。None = 終わりの印を持たない
#   stamp       … 成功の刻を書くファイル (logs/ の中)。軍師一号が cmd_1439 で据えた 2 本
JOBS = [
    dict(name="gate_nightly", period_min=1440, grace_min=360,
         log="gate_nightly.log", end_pat=r"── \[gate_nightly\] 終了 ", stamp=None,
         note="毎朝 06:30"),
    dict(name="idle_revive_scan", period_min=3, grace_min=27,
         log="idle_revive_scan.log", end_pat=None, stamp=None,
         note="3 分毎。開始の印だけ持ち、終わりの印を持たない"),
    dict(name="stall_watchdog_scan", period_min=15, grace_min=45,
         log="stall_watchdog_scan.log", end_pat=None, stamp=None,
         note="15 分毎。印を 1 つも持たない。この検めの相乗り先そのもの"),
    dict(name="engine_devserver_morning_check", period_min=1440, grace_min=360,
         log="engine_devserver_morning_check.log",
         end_pat=r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] ", stamp=None,
         note="毎朝 06:55。1 走行 = 1 行 (行そのものが終わりの印)"),
    dict(name="pf_account_rename_reminder", period_min=None, grace_min=1440,
         log="pf_account_rename_reminder.log", end_pat=None, stamp=None,
         note="8/3 09:00 の 1 度きり。期日前は検めない", due="2026-08-03T09:00:00"),
    dict(name="AituberFBackupToD", period_min=1440, grace_min=360,
         log=None, end_pat=None, stamp="last_backup_f_to_d.txt",
         note="毎日 02:00 (Windows)。証は軍師一号が cmd_1439 で据えた"),
    dict(name="AituberDvcGc", period_min=1440, grace_min=360,
         log=None, end_pat=None, stamp="last_dvc_gc_mirror.txt",
         note="毎日 03:00 (Windows)。証は軍師一号が cmd_1439 で据えた"),
]

_TS_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})")


def sniff_encoding(raw: bytes):
    """バイト列の並べ方 (encoding) を判じて名前を返す。

    何ゆえ「行が読めたか」では足りないか (2026-07-28 に四号と軍師二号が現物で示した)
    UTF-16 を utf-8 として読んでも、改行の \\n が 1 バイト残るので行は刻まれます。
    ゆえに「1 行でも読めたか」を見る canary は、UTF-16 のファイルで現に緑になります。
    中身の綴りには一つも当たらないのに、です。
    見るべきは行数ではなく、並べ方そのものです。
    """
    if raw.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        return "utf-32"
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return "utf-16"
    if raw.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    # BOM の無い UTF-16。NUL が多いことで判じます (utf-8 の本文に NUL は出ません)。
    if raw and raw.count(b"\x00") / len(raw) > 0.05:
        return "utf-16"
    return "utf-8"


def read_text(path: Path):
    """並べ方を先に判じてから読む。(本文, 判じた並べ方) を返す。読めなければ (None, 理由)。

    書く側は Windows の PowerShell で、読む側は WSL の python です。
    書いた者は正しく、読む者も正しく、間に在る並べ方だけが食い違います。
    """
    try:
        raw = path.read_bytes()
    except OSError:
        return None, "読めません"
    enc = sniff_encoding(raw)
    try:
        return raw.decode(enc, errors="replace"), enc
    except (LookupError, UnicodeError):
        return raw.decode("utf-8", errors="replace"), enc


def _parse_ts(text):
    """文字列の中の最初の日時を naive local として返す。読めなければ None。

    BOM と CR を先に落とします。Windows 側が書いたファイルには BOM が付くことが
    あるためです (軍師一号が cmd_1439 で現に踏みました = テストは全数 緑なのに
    本番は初日から読めていませんでした)。
    """
    if text is None:
        return None
    text = text.lstrip("﻿").replace("\r", "")
    m = _TS_RE.search(text)
    if not m:
        return None
    try:
        return datetime.datetime(*(int(x) for x in m.groups()))
    except ValueError:
        return None


def _last_match(path: Path, pat):
    """path の中で pat に当たる最後の行を返す (無ければ None)。"""
    rx = re.compile(pat)
    text, _enc = read_text(path)
    if text is None:
        return None
    last = None
    for line in text.splitlines():
        if rx.search(line):
            last = line
    return last


def check_job(job, logs_dir: Path, now: datetime.datetime):
    """1 本を検めて所見を返す。鳴らすか鳴らさないかは呼び出す側が決める。"""
    out = dict(name=job["name"], note=job["note"], verdict="OK", detail="", age_min=None)

    # 期日前の 1 度きりの物は検めない (走っていないのが正しい姿のため)
    if job.get("due"):
        due = _parse_ts(job["due"])
        if due and now < due:
            out["verdict"] = "OK"
            out["detail"] = f"期日 {job['due'][:10]} の前なので検めていません"
            return out

    # ① 成功の刻をファイルへ書く形 (軍師一号が据えた 2 本)
    if job.get("stamp"):
        p = logs_dir / job["stamp"]
        if not p.is_file():
            out["verdict"] = "MISSING"
            out["detail"] = f"成功の記録がありません ({p.name})"
            return out
        text, enc = read_text(p)
        dt = _parse_ts(text)
        if dt is None:
            # 並べ方を必ず名乗ります。「日時が書かれていない」と
            # 「書いてあるが並べ方が違って読めない」は、直す先が別のためです。
            out["verdict"] = "MISSING"
            out["detail"] = (f"成功の記録を日時として読めません ({p.name}・"
                             f"並べ方={enc})")
            return out
        age = (now - dt).total_seconds() / 60
        out["age_min"] = int(age)
        limit = job["period_min"] + job["grace_min"]
        if age > limit:
            out["verdict"] = "STALE"
            out["detail"] = (f"最後の成功から {int(age/1440)} 日 "
                             f"({int(age)} 分・許容 {limit} 分) — {p.name}")
        else:
            out["detail"] = f"最後の成功 {dt:%F %T} ({int(age)} 分前)"
        return out

    # ② log の中の終わりの印を読む形
    log = logs_dir / job["log"]
    if not log.is_file():
        out["verdict"] = "MISSING"
        out["detail"] = f"log がありません ({job['log']})"
        return out

    skip = _last_match(log, SKIP_PAT)
    if job["end_pat"] is None:
        # 終わりの印を持たない場合、log の更新時刻を代わりに使いません。
        # 更新時刻は「誰かが何か書いた」しか言えず、途中で死んでも更新されるためです
        # (代わりに使えば、この cmd がずっと狩ってきた形を自分で作ることになります)。
        out["verdict"] = "MISSING"
        out["detail"] = (f"終わりの印がありません ({job['log']}) — "
                         f"log の更新時刻は「終わった」ことを示せないので使いません")
        return out

    last = _last_match(log, job["end_pat"])
    if last is None:
        out["verdict"] = "MISSING"
        out["detail"] = f"終わりの印が 1 本もありません ({job['log']})"
        return out
    dt = _parse_ts(last)
    if dt is None:
        # 終わりの印はあるが日時が読めない場合は、log の更新時刻で代用します。
        # 代用したことは必ず名乗ります (黙って代用すると、次の者は日時が読めたと思うため)。
        dt = datetime.datetime.fromtimestamp(log.stat().st_mtime)
        out["detail"] = "(終わりの印に日時が無いので log の更新時刻で代用) "
    age = (now - dt).total_seconds() / 60
    out["age_min"] = int(age)
    limit = job["period_min"] + job["grace_min"]
    if age > limit:
        # 見送りの名乗りがあれば鳴らしません (「見送った」と「死んだ」を分けます)
        if skip:
            out["verdict"] = "SKIPPED"
            out["detail"] += f"自分で見送りを名乗っています ({int(age)} 分前が最後の終わり)"
        else:
            out["verdict"] = "STALE"
            out["detail"] += (f"最後に終わったのが {int(age)} 分前 "
                              f"(許容 {limit} 分) — {job['log']}")
    else:
        out["detail"] += f"最後に終わった {dt:%F %T} ({int(age)} 分前)"
    return out


def scan(logs_dir: Path = None, now: datetime.datetime = None):
    """7 本を検めて (所見の一覧, 母数) を返す。"""
    logs_dir = logs_dir or LOGS_DIR
    now = now or datetime.datetime.now()
    return [check_job(j, logs_dir, now) for j in JOBS], len(JOBS)


def format_alert(findings):
    """家老へ渡す 1 通。母数と、塞げていない範囲を必ず載せる。"""
    bad = [f for f in findings if f["verdict"] in ("STALE", "MISSING")]
    stale = "・".join(f"{f['name']}={f['detail']}" for f in bad if f["verdict"] == "STALE")
    missing = "・".join(f["name"] for f in bad if f["verdict"] == "MISSING")
    return ("【定時実行の見張り】終わった証で検めた結果 "
            f"母数={len(findings)}本 異常={len(bad)}本。"
            + (f"古い={stale} " if stale else "")
            + (f"証を持たない={missing} " if missing else "")
            + "対応=古い側は、その定時実行が現に走っているかを見てください。"
            + "証を持たない側は、走行の終わりに 1 行 書く形を足せば検められます。"
            + "この見張り自身は 15 分毎の監視スクリプトに相乗りしているので、"
            + "そちらが死ねば一緒に黙ります (そこは塞げていません・cmd_1465)")


def canary(logs_dir: Path = None):
    """読む file の並べ方の内訳そのものを刷る。判じる口が死んでいれば ここで判る。

    「何か出るか」ではなく「並べ方を現に見たか」を見る形です。
    utf-8 以外が 1 本も出ない状態が続いたら、判じる口が死んでいる公算があります
    (その時こそ、作り物で撃って口が生きていることを確かめてください)。
    """
    logs_dir = logs_dir or LOGS_DIR
    seen, missing = {}, []
    for job in JOBS:
        name = job.get("stamp") or job.get("log")
        if not name:
            continue
        p = logs_dir / name
        if not p.is_file():
            missing.append(name)
            continue
        try:
            raw = p.read_bytes()
        except OSError:
            missing.append(name)
            continue
        enc = sniff_encoding(raw)
        seen.setdefault(enc, []).append((name, len(raw), raw.count(b"\x00")))

    print(f"# canary 採取 {time.strftime('%F %T')} / logs={logs_dir}")
    for enc in sorted(seen):
        for name, size, nul in seen[enc]:
            print(f"SL_CANARY enc={enc} bytes={size} nul={nul} file={name}")
    print("SL_CANARY 内訳=" + str({k: len(v) for k, v in sorted(seen.items())})
          + f" file無し={len(missing)}本"
          + ("" if missing else "")
          + " (行数ではなく並べ方を見ています。"
            "UTF-16 は utf-8 として読んでも行は刻まれるので、行数では捕えられません)")
    if missing:
        print("SL_CANARY file無し=" + "・".join(missing))
    # 判じる口そのものを、既知の作り物で撃ちます (この一行が緑の理由を分けます)。
    probe = {"utf-16": "x".encode("utf-16"), "utf-8-sig": "﻿x".encode("utf-8"),
             "utf-8": b"x"}
    bad = [k for k, v in probe.items() if sniff_encoding(v) != k]
    print("SL_CANARY 判じる口=" + ("生きています" if not bad
                                   else f"死んでいます (外した={bad})"))
    return 1 if bad else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="定時実行 7 本の『終わった証』を検める")
    ap.add_argument("--logs-dir", type=Path, default=None, help="テスト用に logs/ を差し替える")
    ap.add_argument("--now", type=str, default=None, help="テスト用に『今』を差し替える (ISO)")
    ap.add_argument("--canary", action="store_true",
                    help="読む file の並べ方の内訳を刷る (中身でなく『現に見たか』を見る)")
    a = ap.parse_args(argv)
    if a.canary:
        return canary(a.logs_dir)
    now = _parse_ts(a.now) if a.now else None
    findings, total = scan(a.logs_dir, now)
    print(f"# 採取 {time.strftime('%F %T')} / 母数 {total} 本")
    for f in findings:
        print(f"SL_JOB={f['name']} SL_VERDICT={f['verdict']} SL_DETAIL={f['detail']}")
    bad = [f for f in findings if f["verdict"] in ("STALE", "MISSING")]
    print(f"[liveness] 母数={total}本 OK={sum(1 for f in findings if f['verdict']=='OK')} "
          f"STALE={sum(1 for f in findings if f['verdict']=='STALE')} "
          f"MISSING={sum(1 for f in findings if f['verdict']=='MISSING')} "
          f"SKIPPED={sum(1 for f in findings if f['verdict']=='SKIPPED')}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
