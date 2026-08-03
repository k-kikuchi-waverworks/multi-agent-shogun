#!/usr/bin/env python3
"""承認された分だけを退避させる。YAML を組み直さず、テキストの塊のまま移す。

★承認の一文 (--approved) と控えの場所 (--backup) の両方が無いと1件も動かない。★
退避の後に検算し、1つでも合わなければ控えから戻して非0で終わる。
"""
import argparse
import collections
import hashlib
import pathlib
import shutil
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from scan import OPEN_STATUSES, split_inbox, split_ledger  # noqa: E402

ARCHIVE_HEADER = """\
# ============================================================
# {name} ARCHIVE ({stamp})
# 退避基準: {reason}
# 承認: {approved}
# 非破壊: 正本から1文字も変えずに移した。
# 戻し方: この file の当該の塊を、正本の一覧の下へそのまま貼れば戻る。
# ============================================================
"""


def md5(path):
    return hashlib.md5(path.read_bytes()).hexdigest()


def restore_entry(target, source=None, created=False):
    """戻し方を1本ぶん書き留める。

    target  = 触る現物
    source  = その現物を戻す控え (名前で決めない。呼ぶ側が対応を決める)
    created = この回に新しく作った file か。真なら「戻す」= 消す
    """
    return {"target": pathlib.Path(target), "source": source, "created": created}


def check_backup(entries):
    """控えに現物が在るかを、名前ではなく現物で1本ずつ確かめる。

    在ることに加えて、中身が現物と一致することまで見る。
    足りない物があれば、その名を挙げて返す (空なら全部 揃っている)。
    """
    missing = []
    for e in entries:
        if e["created"]:
            continue  # この回に作る file。控えは要らない (戻す時は消す)
        t, b = e["target"], e["source"]
        if b is None or not pathlib.Path(b).is_file():
            missing.append(f"{t} の控えが無い (在るべき場所 = {b})")
        elif t.is_file() and md5(pathlib.Path(b)) != md5(t):
            missing.append(f"{t} の控えが古い (中身が今の現物と違う)")
    return missing


def die(msg, entries):
    """検算が合わなかった時。戻せた物だけ戻し、戻せなかった物は大きく報せて落ちる。"""
    print(f"NG: {msg}", file=sys.stderr)
    failed = []
    for e in entries:
        t = e["target"]
        if e["created"]:
            # この回に新しく作った file。戻すとは、作る前の姿 = 無い状態にすることである。
            try:
                if t.exists():
                    t.unlink()
                print(f"    この回に作った file を消した: {t}", file=sys.stderr)
            except OSError as ex:  # noqa: PERF203
                failed.append((t, f"消せなかった — {ex}"))
            continue
        b = e["source"]
        if b is not None and pathlib.Path(b).is_file():
            try:
                shutil.copy2(b, t)
                print(f"    控えから戻した: {t}", file=sys.stderr)
            except OSError as ex:
                failed.append((t, f"控えから戻せなかった — {ex}"))
        else:
            failed.append((t, f"控えに現物が無い (在るべき場所 = {b})"))

    if failed:
        bar = "!" * 68
        print(f"\n{bar}", file=sys.stderr)
        print("★戻せなかった。次の file は壊れたままである★", file=sys.stderr)
        for t, why in failed:
            print(f"    {t}", file=sys.stderr)
            print(f"        {why}", file=sys.stderr)
        print("", file=sys.stderr)
        print("撃ち直さないこと。手で戻すこと。戻し道は2本ある。", file=sys.stderr)
        print("    1. 控えのディレクトリ", file=sys.stderr)
        print("    2. D: の30分ごとの控え /mnt/d/backup/multi-agent-shogun/queue_backup/", file=sys.stderr)
        print(f"{bar}", file=sys.stderr)
    sys.exit(2)


def parses(path):
    try:
        yaml.safe_load(path.read_text(encoding="utf-8"))
        return True
    except Exception as e:  # noqa: BLE001
        print(f"    YAML として読めない: {path} — {e}", file=sys.stderr)
        return False


def do_ledger(args, backup):
    src = pathlib.Path(args.ledger)
    dst = pathlib.Path(args.ledger_archive)
    arc_existed = dst.exists()

    # 触る前に、この2本をどの控えから戻すかを決めておく。名前で決めない。
    entries = [
        restore_entry(src, backup / src.name),
        restore_entry(dst, backup / "archive" / dst.name, created=not arc_existed),
    ]
    missing = check_backup(entries)
    if missing:
        print("NG: 控えが揃っていない。控えが唯一の戻し道ゆえ、何もせず止まる。", file=sys.stderr)
        for m in missing:
            print(f"    {m}", file=sys.stderr)
        sys.exit(2)

    header, blocks, raw = split_ledger(src)
    if header + "".join(b["text"] for b in blocks) != raw:
        die("台帳を塊に切って繋ぎ直すと元と違う", entries)

    statuses = {s.strip() for s in args.statuses.split(",") if s.strip()}
    open_asked = statuses & OPEN_STATUSES
    if open_asked:
        print(
            f"NG: {sorted(open_asked)} は open である。open な cmd はこの skill では移せない。",
            file=sys.stderr,
        )
        sys.exit(2)
    ids = {i.strip() for i in args.ids.split(",") if i.strip()}
    keep_ids = {i.strip() for i in args.keep_ids.split(",") if i.strip()}

    move, keep = [], []
    for b in blocks:
        picked = (b["status"] in statuses or b["id"] in ids) and b["id"] not in keep_ids
        (move if picked else keep).append(b)

    # --ids で open を名指しされた時は、書く前に止める。
    # 書いてから検算で戻すと「open なのに正本から消えた」という事故めいた文言が出る。
    open_named = [b["id"] for b in move if b["status"] in OPEN_STATUSES]
    if open_named:
        print(
            f"NG: {open_named} は open である。open な cmd はこの skill では移せない。"
            "何も動かさずに止まる。",
            file=sys.stderr,
        )
        sys.exit(2)

    if not move:
        print("退避する物が1件も無い。何も動かさずに終わる。")
        return

    if arc_existed:
        arc_before = dst.read_text(encoding="utf-8")
    else:
        arc_before = ARCHIVE_HEADER.format(
            name=src.name, stamp=args.stamp, reason=args.reason, approved=args.approved
        ) + "commands:\n"
    arc_after = arc_before + "".join(b["text"] for b in move)
    new_main = header + "".join(b["text"] for b in keep)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(arc_after, encoding="utf-8")
    src.write_text(new_main, encoding="utf-8")

    # ── 検算 ────────────────────────────────────────────────
    _, keep2, _ = split_ledger(src)
    _, arc2, _ = split_ledger(dst)
    if len(keep2) + len(move) != len(blocks):
        die(f"件数が合わない: 残{len(keep2)} + 移{len(move)} ≠ 元{len(blocks)}", entries)
    if {b["id"] for b in keep2} | {b["id"] for b in move} != {b["id"] for b in blocks}:
        die("id の集合が元と違う", entries)
    dup = [k for k, v in collections.Counter(b["id"] for b in arc2).items() if v > 1]
    if dup:
        die(f"退避先に id の重複が増えた: {dup}", entries)
    left_open = [b["id"] for b in blocks if b["status"] in OPEN_STATUSES]
    kept_ids = {b["id"] for b in keep2}
    gone = [i for i in left_open if i not in kept_ids]
    if gone:
        die(f"open なのに正本から消えた: {gone}", entries)
    moved_text = {b["text"] for b in move}
    arc_text = {b["text"] for b in arc2}
    if not moved_text <= arc_text:
        die("移した塊が退避先に1文字も違わない形で入っていない", entries)
    if not parses(src) or not parses(dst):
        die("退避の後の file が YAML として読めない", entries)

    print(f"台帳 = {len(blocks)}本 → 正本 {len(keep2)}本 / 退避 {len(move)}本 ({dst})")
    print(f"    open {len(left_open)}本は全部 正本に在る。id の重複なし。両方 YAML として読める。")


def do_inbox(args, backup):
    arc_dir = pathlib.Path(args.inbox_archive)
    inbox_files = sorted(pathlib.Path(args.inbox_dir).glob("*.yaml"))

    # 1本目に触る前に、触りうる物すべての控えを確かめる。
    # 途中で止まると、そこまでに移した file だけが動いた半端な形で残るためである。
    pre = [restore_entry(p, backup / "inbox" / p.name) for p in inbox_files]
    if arc_dir.is_dir():
        pre += [
            restore_entry(a, backup / "archive" / arc_dir.name / a.name)
            for a in sorted(arc_dir.glob("*.yaml"))
        ]
    lack = check_backup(pre)
    if lack:
        print("NG: 控えが揃っていない。控えが唯一の戻し道ゆえ、何もせず止まる。", file=sys.stderr)
        for m in lack:
            print(f"    {m}", file=sys.stderr)
        sys.exit(2)

    arc_dir.mkdir(parents=True, exist_ok=True)
    for p in inbox_files:
        header, blocks, raw = split_inbox(p)
        if not blocks:
            continue
        if header + "".join(b["text"] for b in blocks) != raw:
            print(f"    飛ばす ({p.name} は塊に切ると元に戻らない)")
            continue
        unread_before = sum(1 for b in blocks if b["unread"])
        read_idx = [i for i, b in enumerate(blocks) if not b["unread"]]
        keep_read = set(read_idx[-args.keep_read :]) if args.keep_read else set()
        # 中身の同値で振り分けない。同じ本文の既読が2件あると両方 落ちるためである。
        move_idx = {i for i in read_idx if i not in keep_read}
        move = [b for i, b in enumerate(blocks) if i in move_idx]
        keep = [b for i, b in enumerate(blocks) if i not in move_idx]
        if not move:
            continue

        dst = arc_dir / p.name
        arc_existed = dst.exists()
        # 触る前に、この2本をどの控えから戻すかを決めておく。
        # 退避先の控えは inbox の控えとは別の場所に在る。名前で決めると
        # 退避先へ inbox の写しを上書きし、前の便りを消してしまう。
        entries = [
            restore_entry(p, backup / "inbox" / p.name),
            restore_entry(
                dst, backup / "archive" / arc_dir.name / p.name, created=not arc_existed
            ),
        ]
        lack = check_backup(entries)
        if lack:
            print(f"NG: {p.name} の控えが揃っていない。この file には触らずに止まる。", file=sys.stderr)
            for m in lack:
                print(f"    {m}", file=sys.stderr)
            sys.exit(2)

        arc_before = (
            dst.read_text(encoding="utf-8")
            if arc_existed
            else ARCHIVE_HEADER.format(
                name=p.name, stamp=args.stamp, reason="既読のみ (未読は1件も移さない)",
                approved=args.approved,
            ) + "messages:\n"
        )
        dst.write_text(arc_before + "".join(b["text"] for b in move), encoding="utf-8")
        p.write_text(header + "".join(b["text"] for b in keep), encoding="utf-8")

        _, keep2, _ = split_inbox(p)
        _, arc2, _ = split_inbox(dst)
        if len(keep2) + len(move) != len(blocks):
            die(f"{p.name}: 件数が合わない", entries)
        if sum(1 for b in keep2 if b["unread"]) != unread_before:
            die(f"{p.name}: ★未読が消えた★", entries)
        if not {b["text"] for b in move} <= {b["text"] for b in arc2}:
            die(f"{p.name}: 移した塊が退避先に元のまま入っていない", entries)
        if not parses(p) or not parses(dst):
            die(f"{p.name}: 退避の後の file が YAML として読めない", entries)
        print(
            f"    {p.name:16s} 全{len(blocks):3d}件 → 残{len(keep2):3d} / 退避{len(move):3d}"
            f"  (未読 {unread_before}件は全部 残った)"
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--approved", required=True, help="人が承認した内容の一文。空は不可")
    ap.add_argument("--backup", required=True, help="控えの場所。無ければ何もせず止まる")
    ap.add_argument("--stamp", required=True, help="日付 (date コマンドで取った値)")
    ap.add_argument("--target", choices=["ledger", "inbox"], required=True)
    ap.add_argument("--reason", default="承認された状態の cmd")
    ap.add_argument("--ledger", default="queue/shogun_to_karo.yaml")
    ap.add_argument("--ledger-archive", default="")
    ap.add_argument("--statuses", default="", help="退避する status (カンマ区切り)")
    ap.add_argument("--ids", default="", help="名指しで退避する id (カンマ区切り)")
    ap.add_argument("--keep-ids", default="", help="status に当たっても残す id")
    ap.add_argument("--inbox-dir", default="queue/inbox")
    ap.add_argument("--inbox-archive", default="")
    ap.add_argument("--keep-read", type=int, default=5)
    args = ap.parse_args()

    if not args.approved.strip():
        print("NG: 承認の一文が空。承認なしには1件も動かさない。", file=sys.stderr)
        return 2
    # 空文字を Path に渡すと「.」(今いるディレクトリ) になり、控えの検査を素通りする。
    if not args.backup.strip():
        print("NG: 控えの場所が空。控えが唯一の戻し道ゆえ、何もせず止まる。", file=sys.stderr)
        return 2
    backup = pathlib.Path(args.backup)
    if not backup.is_dir() or not any(backup.iterdir()):
        print(f"NG: 控えが無い ({backup})。控えが唯一の戻し道ゆえ、何もせず止まる。", file=sys.stderr)
        return 2

    if args.target == "ledger":
        if not args.ledger_archive:
            args.ledger_archive = f"queue/archive/shogun_to_karo_archive_{args.stamp}.yaml"
        if not args.statuses and not args.ids:
            print("NG: 退避する status も id も指定が無い。", file=sys.stderr)
            return 2
        do_ledger(args, backup)
    else:
        if not args.inbox_archive:
            args.inbox_archive = f"queue/archive/inbox_{args.stamp}"
        do_inbox(args, backup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
