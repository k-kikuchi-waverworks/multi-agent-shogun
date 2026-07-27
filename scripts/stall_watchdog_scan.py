#!/usr/bin/env python3
# stall_watchdog_scan.py — cmd_552 Phase 3 Watchdog: report↔task YAML 突合 scan
#
# Detects bookkeeping omissions where a task YAML stays `status: assigned`
# while the corresponding report YAML already records completion
# (`done`/`completed`/`success`) past a threshold elapsed time.
#
# Usage:
#   python3 scripts/stall_watchdog_scan.py [--dry-run] [--threshold-min N] [--json]
#     [--queue-root PATH]
#
# On hit: writes a `stall_watchdog_bookkeeping_alert` message to karo inbox via
# `scripts/inbox_write.sh`.

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TASKS_DIR = REPO_ROOT / "queue" / "tasks"
DEFAULT_REPORTS_DIR = REPO_ROOT / "queue" / "reports"
DEFAULT_INBOX_DIR = REPO_ROOT / "queue" / "inbox"
INBOX_WRITE_SH = REPO_ROOT / "scripts" / "inbox_write.sh"

COMPLETION_STATUSES = {"done", "completed", "success"}
DEFAULT_THRESHOLD_MIN = 30
SCANNED_AGENT_PREFIXES = ("ashigaru",)
SCANNED_AGENT_NAMES = {"gunshi"}

# ── 10 分規律の検め (cmd_1454) ──────────────────────────────────────────
# 規の出所 = instructions/karo.md の節
#   「🚨 MANDATORY: Ash Report Receipt → Karo MUST Dispatch QC Task Explicitly」の
#   **Rule** (絶対遵守)「Every ash report … within ≤10 min of arrival」と、
#   同節末の「Stall Watchdog integration: every Watchdog pass MUST scan …」。
# ★行番号で引かぬ★ = 2026-07-28 06:40〜06:44 の間に此の file の行番号が現に動いた
#   (四号が同 file を書き替えておる最中であった。1400 → 1376)。★動いておる file の
#   行番号を出所として写すな★ — 条D-3 が刻について申す所と同じ族である。
# 之を撃つ機械が【本 script に無かった】。karo.md の Watchdog 節「(B) 🚨 MANDATORY:
# gunshi inbox の未処理 report_received scan」に python の一節が埋まっておるが、
# ★queue/inbox/gunshi.yaml を読む★ — 此の file の messages は 0 件で、
# 現の往来は gunshi1.yaml (45 便) / gunshi2.yaml (44 便) の側に在る
# (2026-07-28 06:40 に己で数え直した)。
# 併せて型も食い違う = 一節は report_received のみを見るが、足軽→軍師の現の型は
# ★report が 18 件・task_completed が 4 件・report_received は 1 件★
# (gunshi1・from 別に実測。gunshi2 側の報告族は 0 件で、悉く家老の便であった)。
# ⇒ file 名と型の二重の食い違いゆえ、走らせても必ず 0 を返す =「見ておらぬ 0」。
#
# ★射程を先に名乗る (条6)★:
#   本検めが見ておるのは「軍師の inbox に、足軽の報告が未読のまま N 分 居る」ことだけ。
#   ★「家老が QC の任を起こしたか」を直に見てはおらぬ★ (queue/tasks/gunshi*.yaml を
#   突き合わせてはおらぬ)。家老が任を配り、軍師がまだ読んでおらぬ間も鳴る。
#   即ち ★偽陽性の向きへ倒してある★ — 沈黙を潰す任ゆえ之を選んだ。
QC_INBOX_GLOB = "gunshi*.yaml"
QC_DEFAULT_THRESHOLD_MIN = 10
# 型は ★現物から採った★ (推測でない)。report_received だけを見る形が
# 現に 0 を返す元凶であったゆえ、報告族を束で見る。
QC_REPORT_TYPES = {"report", "report_received", "task_completed"}
# 差出人は足軽に限る = 家老/inbox_watcher の便 (task_assigned・note 等) を母数に混ぜぬ。
# ★之が【己を母数から外す】(条C) の実体でもある★ — 本番人が名乗る from は
# "stall_watchdog" ゆえ、足軽の prefix を通らぬ。構造の側で外れておる。
#
# ★ここに元は QC_SELF_SENDERS = {"stall_watchdog"} という第二の錠を置いておった。
#   2026-07-28 06:41 の変異試験で【落としても赤が 1 本も出ぬ】と実測し、外した。★
#   理由 = 二つの錠が互いを隠し、どちらを壊しても試験が緑のまま通った
#   (M5 = 自錠を潰す → 赤 0 本 / M7 = prefix を潰す → 赤 0 本)。
#   ★「錠が二つ在るゆえ安心」は、片方ずつ壊れても誰も気付かぬ形であった。★
#   家老が 06:36 に karo.md の盲目な写しへ下した裁 (直さず落とす) を、己の錠へ当てた。
QC_SENDER_PREFIXES = ("ashigaru",)


# status は機械 token ([a-z_]) — 最初の ASCII 語 run が status 本体。装飾は何であれ語ではない。
_STATUS_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]*")


def normalize_status(value):
    """status 文字列を照合可能な正規形へ (最初の ASCII 語 run の抽出 + lowercase)。

    idle_revive_scan.py の同名関数と同型 (cmd_1356 d8fc7fd の同処方)。家老の帳簿慣行
    `status: 'assigned   # 2026-07-26 07:23 家老dispatch=…'` は YAML 上【引用符内の
    一つの文字列】であり、生のまま "assigned" と完全一致照合すると注記付き task が
    全て scan に不可視になる。本 scan では task 側 (assigned 照合) と report 側
    (COMPLETION_STATUSES 照合) の両方が同じ穴を持っておった = 帳簿漏れ alert が
    注記1つで永久に沈黙する (alert は「撃たれなかった」ことに誰も気付けぬ型)。
    注記は運用上有用ゆえ家老は書き続ける —「注記が在っても読める」側で吸収する。

    ★初版 (先頭空白 token + 末尾 :;,. 落とし) は装飾の blocklist であった★ —
    軍師二号 OBS-2 が『★assigned★家老dispatch★』(空白を挟まぬ ★ 密着)・全角括弧/
    全角句読点・…・—・/ の 9 形で盲目が戻ることを実証した (家老は ★ を常用ゆえ
    現実の的)。blocklist は次の装飾文字で必ず破れる — ★語の側を allowlist で取る★:
    status は機械 token ([A-Za-z][A-Za-z0-9_]*) ゆえ最初の ASCII 語 run が status。
    最初の run を採る = 注記中の状態語には乗っ取られぬ (偽 HIT を作らぬ側の契約
    T-SWD-002 は据え置き)。ASCII 語が一つも無ければ "" (従来どおり不可視)。
    idle_revive 側との copy drift は各 copy の変異登録 (MUT-1154-001,003 /
    MUT-0552-001,002,004) が独立に見張る。
    """
    if not isinstance(value, str):
        return value
    m = _STATUS_TOKEN_RE.search(value)
    return m.group(0).lower() if m else ""


def parse_task(path: Path):
    try:
        with path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"[stall_watchdog] WARN: task YAML parse failed: {path}: {e}",
              file=sys.stderr)
        return None
    if not isinstance(data, dict) or not isinstance(data.get("task"), dict):
        return None
    t = data["task"]
    # status は正規化して返す = 消費点 (scan の assigned 照合) が注記付きでも読める。
    # 出所は本関数の1点のみ (二重管理禁)。
    # updated_at = ★task_id 再利用を再dispatchと見分けるための刻★ (cmd_1359)。
    return (t.get("task_id"), t.get("parent_cmd"), normalize_status(t.get("status")),
            t.get("updated_at") or t.get("timestamp"))


def extract_report_record(doc):
    if not isinstance(doc, dict):
        return None
    inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
    task_id = inner.get("task_id") or inner.get("primary_task")
    # report 側も同じ注記慣行がありうる — task 側と同じ正規形で読む (出所は本関数の1点)。
    # alert 本文へ運ばれるのも正規化 token = 注記の生文字列を inbox へ流さぬ。
    status = normalize_status(inner.get("status"))
    ts = inner.get("timestamp")
    return (task_id, status, ts)


def parse_iso_to_naive_local(s):
    if not isinstance(s, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone().replace(tzinfo=None)
    return dt


def parse_report_latest(path: Path):
    """(最新 record, 其の刻, ★読めなんだか★) を返す.

    ★cmd_1394 同族 (2026-07-27・家老 03:31 下命)★:
      従来は parse 落ちを (None, None) で返しており、★呼び手からは
      「report は在るが、此の task_id の記録が無い」と区別がつかなんだ★ =
      ★黙って skip★ になっておった。
      ⇒ 本 scan の実害は idle_revive とは【向きが逆】である:
        idle_revive = 読めぬ物へ ★撃ってしまう★ (偽陽性)
        stall_watchdog = 読めぬ物を ★見逃す★ (偽陰性) =
          ★真の帳簿漏れが、report が壊れておるという別の理由で永久に鳴らぬ★。
      ★しかも log は「帳簿漏れ hit なし。assigned=N」と申す★ =
      ★【全員健全】と読める★ = ★之が四号の申した「無い木は無いと申さぬ」の族★。
    ⇒ 第三の値として返し、呼び手が ★外したことを名乗れる★ ようにする。
    """
    try:
        with path.open(encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
    except yaml.YAMLError as e:
        print(f"[stall_watchdog] WARN: report YAML parse failed: {path}: {e}",
              file=sys.stderr)
        return None, None, True
    latest = None
    latest_dt = None
    for doc in docs:
        rec = extract_report_record(doc)
        if not rec:
            continue
        task_id, status, ts = rec
        if not ts:
            continue
        dt = parse_iso_to_naive_local(ts)
        if dt is None:
            continue
        if latest_dt is None or dt > latest_dt:
            latest, latest_dt = rec, dt
    return latest, latest_dt, False


def should_scan_agent(agent: str) -> bool:
    if agent in SCANNED_AGENT_NAMES:
        return True
    return any(agent.startswith(p) for p in SCANNED_AGENT_PREFIXES)


def redispatch_basis(task_path: Path, task_updated_at, report_dt):
    """★同じ task_id へ新しい手番が載った (再dispatch) か★ を見分ける (cmd_1359)。

    軍師二号の警告 = 本 scan を配線した途端、★真の漏れでないのに鳴り続ける★。
    的は ★家老が同じ task_id へ新しい手番を載せる癖★ である。

    ★運用則で人を縛る道は採らぬ★ — 注記慣行を allowlist で吸収した cmd_1356 と同じ
    考え方で、★「癖を直せ」でなく「癖が在っても読める」側で吸収する★。

    見分け方 = ★task YAML が申告した updated_at が report より新しければ、
    その report は【前の手番】のもの★。★根拠はこれ一つに限る★。

    ★file mtime を代理に使う道は【意図して捨てた】★:
      初版は updated_at 不在時に mtime で代用したが、既存 test 3本が赤くなって
      露見した = ★task file に触れさえすれば genuine な帳簿漏れが黙って消える★。
      漏れとは「帳簿が更新されておらぬ」ことであり、mtime は ★更新の意思★ でなく
      ★触れた事実★ しか映さぬ (整形・別 field の編集・cp でも動く)。
      ⇒ ★これは代理変数で生死を判ずる型であり、家老が 23:39 に dashboard mtime で
      誤って死と判定された事故と同じ形★。本 cmd は沈黙を潰す任ゆえ、
      ★沈黙を生む代理変数を新たに据えるのは本末転倒である★。

    ★updated_at が無ければ「判定不能」= 鳴らす側へ倒す★ (握り潰さぬ)。
    alert には「見分けられなんだ」と明記し、updated_at を書けば止むことを添える
    = ★人を運用則で縛らず、機械が読める形を書く方が得になる★ 向きに寄せる。

    戻り値: (再dispatchか, 根拠の名) — 根拠は alert と log に印字する
            (どの根拠で黙ったかが見えねば、この判定自体が新しい沈黙になる)。
    """
    dt = parse_iso_to_naive_local(task_updated_at)
    if dt is None:
        return False, "none"
    return (dt > report_dt), "updated_at"


def scan(tasks_dir: Path, reports_dir: Path, threshold_min: int, now=None):
    if now is None:
        now = datetime.datetime.now()
    hits = []
    # 再dispatchと見て黙った件数 = ★黙った理由の分母★。0件印字と同じ考え方で、
    # 「鳴らさなかった」が見えねば本判定そのものが新しい沈黙になる (cmd_1359)。
    redispatch_skipped = []
    # assigned_count = scan の目に映った assigned task の分母。hit 0 件時に印字する =
    # 「分母0 (status drift 等で何も見えておらぬ)」と「全員健全 (帳簿漏れなし)」を
    # log 上で区別可能にする (idle_revive の eligible=N と同処方・家老裁定 09:24)。
    assigned_count = 0
    # ★読めなんだ report の簿★ (cmd_1394 同族・家老 03:31)。
    # ★之を分けねば「hit 0 = 全員健全」と読める★ = 判じられなんだ agent が
    # 健全側へ黙って混ざる。★外すなら「外した」と名乗る口を同時に持たせよ★。
    unreadable_reports = []
    for task_path in sorted(tasks_dir.glob("*.yaml")):
        agent = task_path.stem
        if not should_scan_agent(agent):
            continue
        parsed = parse_task(task_path)
        if not parsed:
            continue
        task_id, parent_cmd, task_status, task_updated_at = parsed
        if task_status != "assigned":
            continue
        assigned_count += 1
        report_path = reports_dir / f"{agent}_report.yaml"
        if not report_path.is_file():
            continue
        latest, latest_dt, unreadable = parse_report_latest(report_path)
        if unreadable:
            # ★読めなんだ = 判じられぬ★。★健全 (漏れ無し) と同じ扱いにせぬ★ =
            # ★真の帳簿漏れが、report の壊れという別の理由で永久に鳴らぬ形を断つ★。
            unreadable_reports.append({
                "agent": agent, "task_id": task_id, "parent_cmd": parent_cmd,
                "report": report_path.name,
            })
            continue
        if not latest or latest_dt is None:
            continue
        r_task_id, r_status, _r_ts = latest
        if r_task_id != task_id:
            continue
        # r_status は extract_report_record で正規化済 (注記付き 'completed   # …' も
        # 完了と読める。lowercase も正規化に含まれる)。
        if not isinstance(r_status, str) or r_status not in COMPLETION_STATUSES:
            continue
        elapsed_min = int((now - latest_dt).total_seconds() // 60)
        if elapsed_min < threshold_min:
            continue
        # ★task_id 再利用の裁定 (cmd_1359)★: task 側の刻が report より新しければ、
        # その report は【前の手番】のもの = 帳簿漏れではない (新しい任が走っておる)。
        is_redispatch, basis = redispatch_basis(task_path, task_updated_at, latest_dt)
        if is_redispatch:
            redispatch_skipped.append({
                "agent": agent, "task_id": task_id, "basis": basis,
            })
            continue
        hits.append({
            "agent": agent,
            "task_id": task_id,
            "parent_cmd": parent_cmd,
            "elapsed_min": elapsed_min,
            "report_status": r_status,
            # ★根拠が none = 再dispatchと見分けられなんだ★ = 握り潰さず鳴らすが、
            # 「見分けられておらぬ」ことを alert に明記する (人が判ずるための材料)。
            "redispatch_basis": basis,
        })
    return hits, assigned_count, redispatch_skipped, unreadable_reports


def scan_qc_dispatch(inbox_dir: Path, threshold_min: int, now=None):
    """10 分規律を撃つ検め — cmd_1454。

    ★規の出所は【節の名】で指す。行番号で指さぬ★ (家老 07:04・四号の見立て・cmd_1450 で直した)。
      instructions/karo.md の
      「#### 🚨 MANDATORY: Ash Report Receipt → Karo MUST Dispatch QC Task Explicitly」の節。
    ★何ゆえ★= 元は "karo.md L1319" と書いておったが、案B の合流で当の規は別の行へ動き、
      :1319 は今 全く別の節 (Gunshi Limitations) である。
      ★指し先は生きた顔をしたまま、指す先だけが別物に化けた★ = 本朝ずっと狩っておる族そのもの。
      節名なら行が動いても付いて回る (2026-07-28 実測 = 此の名は karo.md に 1 件のみ = 一意)。
    ★併せて己の非 (cmd_1450 丙・07:2x)★= 此の註の初版は「当の規は :1376 へ動き」と
      ★新しい行番号を書いておった★。而して 07:20 の実測では節の頭は :1394 (作業木)・
      :1373 (HEAD) であり、★:1376 は書いた其の刻から既に違うておった★。
      ⇒ ★行番号を捨てる直しの中で、己が新しい行番号を書いた★ = 同じ族を己で踏んだ。
      ⇒ 之が「行番号を書かぬ」を ★註の中でも★ 守る理由である。

    見る物 = 軍師の inbox に居る【足軽の報告】で、未読のまま threshold_min を超えた物。

    戻り値: (hits, stats)
      stats は ★母数★ である。hit 0 の時に之を印字せねば、
      「見た上で 0」と「そもそも見ておらぬ 0」が log 上で見分けられぬ (条1)。
    """
    if now is None:
        now = datetime.datetime.now()
    hits = []
    stats = {
        "files": 0, "messages": 0, "unread": 0, "report_family": 0,
        # ★canary (家老 06:36 の下命・本任の芯)★:
        #   read の別を問わぬ報告族の総数。0 件なら ★探し方 (file 名か型) が
        #   当たっておらぬ疑い★ = 之こそ karo.md の一節が陥っておった形である
        #   (gunshi.yaml を読み report_received だけを見る ⇒ 恒久に 0)。
        #   ★之を置かねば「見ておらぬ 0」と「無かった 0」が同じ顔で返る。★
        "report_family_all": 0,
        # ★刻が未来の物★ (家老 07:21 の裁・三号 07:17 の実測)。
        #   経過で切る検めは ★未来の刻を永久に拾わぬ★ (elapsed が負ゆえ閾値を超えぬ)。
        #   実測 = ashigaru1_report.yaml の record が 07:45 (file の mtime は 07:08) ⇒ 経過 -28 分。
        #   ★黙って skip すれば、其の報告は検めから消えたまま誰も気付かぬ。★
        #   ⇒ hit にはせぬ (経過が閾値を超えておらぬのは事実) が、★必ず名乗らせる★。
        #   之は条D-3 が【読む側】でなく【検めを盲にする側】の顔で出た物である。
        "future": [],
        "unreadable_files": [], "undated": [],
    }
    for path in sorted(inbox_dir.glob(QC_INBOX_GLOB)):
        stats["files"] += 1
        try:
            with path.open(encoding="utf-8") as f:
                data = yaml.safe_load(f)
        except (OSError, yaml.YAMLError) as e:
            # ★読めなんだ物を健全側へ混ぜぬ★ (parse_report_latest と同じ考え方)。
            print(f"[stall_watchdog] WARN: gunshi inbox parse failed: {path}: {e}",
                  file=sys.stderr)
            stats["unreadable_files"].append(path.name)
            continue
        messages = (data or {}).get("messages") or []
        if not isinstance(messages, list):
            stats["unreadable_files"].append(path.name)
            continue
        stats["messages"] += len(messages)
        for m in messages:
            if not isinstance(m, dict):
                continue
            sender = str(m.get("from") or "")
            is_report_family = (
                any(sender.startswith(p) for p in QC_SENDER_PREFIXES)
                and m.get("type") in QC_REPORT_TYPES
            )
            # canary は ★read の別を問わず★ 数える (既読も母数に入る)。
            if is_report_family:
                stats["report_family_all"] += 1
            if m.get("read"):
                continue
            stats["unread"] += 1
            if not is_report_family:
                continue
            stats["report_family"] += 1
            dt = parse_iso_to_naive_local(m.get("timestamp"))
            if dt is None:
                # ★刻が読めぬ物を黙って落とさぬ★ = 落とした事実を名乗る口を持たせる。
                stats["undated"].append({
                    "inbox": path.name, "id": m.get("id"), "from": sender,
                })
                continue
            elapsed_min = int((now - dt).total_seconds() // 60)
            if elapsed_min < 0:
                # ★刻が未来 = 経過で切る検めから永久に落ちる★ ゆえ、落ちた事実を名乗る。
                stats["future"].append({
                    "inbox": path.name, "id": m.get("id"), "from": sender,
                    "timestamp": str(m.get("timestamp")), "ahead_min": -elapsed_min,
                })
                continue
            if elapsed_min < threshold_min:
                continue
            hits.append({
                "inbox": path.name,
                "msg_id": m.get("id"),
                "from": sender,
                "msg_type": m.get("type"),
                "elapsed_min": elapsed_min,
            })
    return hits, stats


def format_qc_alert_message(hit, threshold_min):
    return (f"🚨 QC dispatch 漏れの疑い: {hit['inbox']} に {hit['from']} の報告 "
            f"({hit['msg_type']}, {hit['msg_id']}) が未読のまま {hit['elapsed_min']} 分。"
            f"karo.md の 10 分規律 (閾値 {threshold_min} 分) を超えておる。"
            f"軍師へ QC の任 (queue/tasks/gunshi*.yaml + clear_command) を起こされたい。"
            f"  ※★本検めが見ておるのは【軍師が未読である】ことのみ★ — "
            f"任を既に配っておるなら、軍師が読めば止む。")


def qc_alert_key(hit):
    return f"qc|{hit['inbox']}|{hit['msg_id']}"


def notify_karo_qc(hit, threshold_min):
    proc = subprocess.run(
        ["bash", str(INBOX_WRITE_SH), "karo",
         format_qc_alert_message(hit, threshold_min),
         "stall_watchdog_qc_dispatch_alert", "stall_watchdog"],
        capture_output=True, text=True,
    )
    return proc


def print_qc_result(qc_hits, stats, threshold_min):
    """10 分規律の検めの結果を印字する。★母数を必ず載せる (条1)★。"""
    for u in stats["unreadable_files"]:
        print(f"ACTION=gunshi_inbox_unreadable INBOX={u} "
              f"⇒ ★読めなんだゆえ QC dispatch 漏れを判じられぬ★ = ★健全と読むな★")
    for u in stats["undated"]:
        print(f"ACTION=gunshi_msg_undated INBOX={u['inbox']} MSG_ID={u['id']} "
              f"FROM={u['from']} ⇒ ★刻が読めぬゆえ経過を測れぬ (hits に載らぬ)★")
    # ★刻が未来の便を黙って落とさぬ (家老 07:21 の裁・三号 07:17 の実測)★
    for u in stats["future"]:
        print(f"ACTION=gunshi_msg_future_dated INBOX={u['inbox']} MSG_ID={u['id']} "
              f"FROM={u['from']} TIMESTAMP={u['timestamp']} AHEAD_MIN={u['ahead_min']} "
              f"⇒ ★便の刻が未来である★ = 経過が負ゆえ "
              f"★閾値を永久に超えず、本検めから黙って消える★。"
              f"刻を直さぬ限り、此の報告の QC 漏れは検め得ぬ")
    for h in qc_hits:
        print(f"QC_DISPATCH_LATE INBOX={h['inbox']} MSG_ID={h['msg_id']} "
              f"FROM={h['from']} MSG_TYPE={h['msg_type']} "
              f"ELAPSED_MIN={h['elapsed_min']}")
    if not qc_hits:
        # ★canary (家老 06:36)★ = 「見ておらぬ 0」と「無かった 0」を分ける。
        if stats["report_family_all"] == 0:
            canary = (" ★★canary 赤 = 報告族が既読も含めて 1 通も無い ⇒ "
                      "探し方 (file 名か型) が当たっておらぬ疑い。"
                      "此の 0 を『漏れ無し』と読むな★★")
        else:
            canary = (f" (canary 緑 = 既読も含めた報告族 "
                      f"{stats['report_family_all']} 通を現に見ておる)")
        print(f"[stall_watchdog] QC dispatch 漏れ hit なし。"
              f"閾値={threshold_min}分 走査file={stats['files']} "
              f"便={stats['messages']} 未読={stats['unread']} "
              f"未読の報告族={stats['report_family']} "
              f"読めぬinbox除外={len(stats['unreadable_files'])} "
              f"刻の読めぬ便除外={len(stats['undated'])} "
              f"刻が未来ゆえ除外={len(stats['future'])}" + canary)


def format_alert_message(hit):
    base = (f"🚨 bookkeeping 漏れ検出: {hit['agent']} task YAML "
            f"({hit['task_id']}, {hit['parent_cmd']}) status=assigned のまま、"
            f"report では {hit['report_status']} で {hit['elapsed_min']} 分経過。"
            f"status=done 更新 + 次 MT 起票要。")
    if hit.get("redispatch_basis") == "none":
        base += ("  ※★同じ task_id への再dispatchと見分けられなんだ★ "
                 "(task YAML に updated_at が無く mtime も読めぬ)。"
                 "新しい手番が走っておるなら updated_at を書けば以後鳴らぬ。")
    return base


# ── alert 疲れの番 (cmd_1359) ────────────────────────────────────────────
# ★常に赤い検知は無視されて死ぬ★ = 3分ごとに同じ漏れを鳴らせば、家老は本 alert を
# 読まなくなる = 沈黙と同じ結末になる。同一の (agent, task_id, report刻) は
# cooldown 内は鳴らさぬ。★但し黙った事実は log に出す (黙って黙らぬ)★。
ALERT_STATE = REPO_ROOT / "queue" / "state" / "stall_watchdog_alerted.yaml"
DEFAULT_COOLDOWN_MIN = 360  # 6h


def _load_alert_state():
    try:
        with ALERT_STATE.open(encoding="utf-8") as f:
            d = yaml.safe_load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, yaml.YAMLError):
        return {}


def _save_alert_state(state):
    try:
        ALERT_STATE.parent.mkdir(parents=True, exist_ok=True)
        tmp = ALERT_STATE.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            yaml.dump(state, f, allow_unicode=True, default_flow_style=False)
        tmp.replace(ALERT_STATE)
    except OSError as e:
        print(f"[stall_watchdog] WARN: alert state 保存失敗 ({e}) — "
              f"次回も鳴る (fail-LOUD 側へ倒す)", file=sys.stderr)


def alert_key(hit):
    return f"{hit['agent']}|{hit['task_id']}"


def in_cooldown(hit, state, cooldown_min, now):
    """cooldown 中なら True。★別の漏れ (elapsed が伸びた同一 key) は鳴らし直さぬ★ —
    同じ帳簿の穴を何度も報せても家老の手番は1つゆえ。key が変われば即座に鳴る。
    """
    last = parse_iso_to_naive_local(state.get(alert_key(hit), {}).get("last_alert"))
    if last is None:
        return False
    return (now - last).total_seconds() < cooldown_min * 60


def notify_karo(hit):
    msg = format_alert_message(hit)
    proc = subprocess.run(
        ["bash", str(INBOX_WRITE_SH), "karo", msg,
         "stall_watchdog_bookkeeping_alert", "stall_watchdog"],
        capture_output=True, text=True,
    )
    return proc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                    help="Print hits to stdout without writing to karo inbox.")
    ap.add_argument("--threshold-min", type=int, default=DEFAULT_THRESHOLD_MIN,
                    help=f"Elapsed-minutes threshold (default {DEFAULT_THRESHOLD_MIN}).")
    ap.add_argument("--json", action="store_true",
                    help="Emit hits as JSON (skeleton for future dashboard wiring).")
    ap.add_argument("--queue-root", type=Path, default=None,
                    help="Override queue root (expects tasks/, reports/, inbox/ subdirs). "
                         "Primarily for tests.")
    ap.add_argument("--qc-threshold-min", type=int, default=QC_DEFAULT_THRESHOLD_MIN,
                    help=f"10 分規律の閾値 (default {QC_DEFAULT_THRESHOLD_MIN})。"
                         f"karo.md「MANDATORY: Ash Report Receipt → Karo MUST Dispatch QC "
                         f"Task Explicitly」の節の ≤10 min に合わせてある (★行番号で指さぬ★)。")
    ap.add_argument("--no-qc-scan", action="store_true",
                    help="10 分規律の検めを走らせぬ (帳簿漏れ scan だけを撃つ時)。")
    ap.add_argument("--cooldown-min", type=int, default=DEFAULT_COOLDOWN_MIN,
                    help=f"同一 (agent, task_id) の再警報を抑える分数 "
                         f"(default {DEFAULT_COOLDOWN_MIN})。★常に赤い検知は無視されて死ぬ★")
    args = ap.parse_args(argv)

    if args.queue_root is not None:
        tasks_dir = args.queue_root / "tasks"
        reports_dir = args.queue_root / "reports"
        inbox_dir = args.queue_root / "inbox"
    else:
        tasks_dir = DEFAULT_TASKS_DIR
        reports_dir = DEFAULT_REPORTS_DIR
        inbox_dir = DEFAULT_INBOX_DIR

    hits, assigned_count, redispatch_skipped, unreadable_reports = scan(
        tasks_dir, reports_dir, args.threshold_min)

    qc_hits, qc_stats = ([], None)
    if not args.no_qc_scan:
        qc_hits, qc_stats = scan_qc_dispatch(inbox_dir, args.qc_threshold_min)

    if args.json:
        print(json.dumps(hits, ensure_ascii=False))
        # ★json の口でも黙らぬ★= hits だけを吐けば、読めなんだ agent は
        # ★json の読み手にとって存在せぬ★ = 同じ穴が口を変えて戻る。
        for u in unreadable_reports:
            print(f"[stall_watchdog] WARN: ACTION=report_unreadable "
                  f"AGENT={u['agent']} TASK_ID={u['task_id']} "
                  f"⇒ ★判じられぬゆえ hits に載らぬ (健全ではない)★", file=sys.stderr)
        # ★json の口でも 10 分規律を落とさぬ★ = 口ごとに射程が違えば、
        # 読み手は「json には出ぬ = 無い」と読む (同じ穴が口を変えて戻る)。
        if qc_stats is not None:
            print(json.dumps({"qc_dispatch_late": qc_hits,
                              "qc_stats": {k: v for k, v in qc_stats.items()}},
                             ensure_ascii=False))
    else:
        # ★黙った件は黙って黙らぬ★ = 再dispatchと見て鳴らさなかった分を必ず印字する。
        # これが見えねば「再dispatch判定が効きすぎて全部握り潰す」状態と
        # 「本当に漏れが無い」状態が log 上で見分けられぬ (分母印字と同じ考え方)。
        for s in redispatch_skipped:
            print(f"[stall_watchdog] 再dispatchと判定し鳴らさず: "
                  f"AGENT={s['agent']} TASK_ID={s['task_id']} 根拠={s['basis']}")
        # ★読めなんだ物を名乗る (cmd_1394 同族・家老 03:31 (2))★ =
        # ★外したことを、外した其の走行で申す★。書き手を名指すのは
        # ★番人が判ずるためでなく、直せる者へ届けるため★である。
        for u in unreadable_reports:
            print(f"ACTION=report_unreadable AGENT={u['agent']} "
                  f"TASK_ID={u['task_id']} PARENT_CMD={u['parent_cmd']} "
                  f"REPORT={u['report']} "
                  f"⇒ ★読めなんだゆえ帳簿漏れを判じられぬ★ = "
                  f"★健全と読むな★。★書き手 {u['agent']} が report を直すまで、"
                  f"此の agent の漏れは鳴らぬ★ "
                  f"(検め方: python3 scripts/report_validate.py "
                  f"queue/reports/{u['agent']}_report.yaml)")
        if not hits:
            # 無出力を契約にせぬ: assigned 存在下で assigned=0 が常態なら scan は
            # 盲目である (2026-07-26 注記drift の型)。分母0の検知層は全PASSと
            # 区別がつかぬ — hit なしでも分母を名指しで残す (家老裁定 09:24)。
            # ★hit 0 を「全員健全」と読ませぬ★ = 読めなんだ数を同じ行に載せる
            # (0 の時も名乗る = 「見ておらぬ」と「見た上で 0」を分ける)。
            print(f"[stall_watchdog] 帳簿漏れ hit なし。assigned={assigned_count} "
                  f"再dispatch除外={len(redispatch_skipped)} "
                  f"読めぬreport除外={len(unreadable_reports)}"
                  + (" ★判じられなんだ agent が居る = 全員健全ではない★"
                     if unreadable_reports else ""))
        for h in hits:
            print(f"AGENT={h['agent']} TASK_ID={h['task_id']} "
                  f"PARENT_CMD={h['parent_cmd']} ELAPSED_MIN={h['elapsed_min']} "
                  f"REPORT_STATUS={h['report_status']}")
        if qc_stats is not None:
            print_qc_result(qc_hits, qc_stats, args.qc_threshold_min)

    if args.dry_run or args.queue_root is not None:
        return 0

    exit_code = 0
    now = datetime.datetime.now()
    state = _load_alert_state()
    for h in hits:
        if in_cooldown(h, state, args.cooldown_min, now):
            # ★黙ったことを黙らぬ★ — cooldown で鳴らさなんだ事実は log に残す。
            print(f"[stall_watchdog] cooldown 中ゆえ再警報せず: "
                  f"{alert_key(h)} (cooldown={args.cooldown_min}分)")
            continue
        proc = notify_karo(h)
        if proc.returncode != 0:
            print(f"[stall_watchdog] ERROR: inbox_write failed for {h['agent']}: "
                  f"{proc.stderr.strip()}", file=sys.stderr)
            exit_code = 1
            continue
        state[alert_key(h)] = {"last_alert": now.isoformat(timespec="seconds"),
                               "task_id": h["task_id"]}
    # ── 10 分規律の警報 (cmd_1454) ──────────────────────────────────
    # cooldown は帳簿漏れと同じ簿を使う (key に "qc|" を冠して衝突を避ける)。
    for h in qc_hits:
        key = qc_alert_key(h)
        last = parse_iso_to_naive_local(state.get(key, {}).get("last_alert"))
        if last is not None and (now - last).total_seconds() < args.cooldown_min * 60:
            print(f"[stall_watchdog] cooldown 中ゆえ再警報せず: "
                  f"{key} (cooldown={args.cooldown_min}分)")
            continue
        proc = notify_karo_qc(h, args.qc_threshold_min)
        if proc.returncode != 0:
            print(f"[stall_watchdog] ERROR: inbox_write failed for QC alert "
                  f"{key}: {proc.stderr.strip()}", file=sys.stderr)
            exit_code = 1
            continue
        state[key] = {"last_alert": now.isoformat(timespec="seconds"),
                      "msg_id": h["msg_id"]}
    _save_alert_state(state)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
