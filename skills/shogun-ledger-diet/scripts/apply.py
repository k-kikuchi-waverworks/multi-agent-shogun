#!/usr/bin/env python3
"""承認された分だけを退避させる。YAML を組み直さず、テキストの塊のまま移す。

★承認の一文 (--approved) と控えの場所 (--backup) の両方が無いと1件も動かない。★
退避の後に検算し、1つでも合わなければ控えから戻して非0で終わる。
"""
import argparse
import collections
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


def die(msg, backup, targets):
    """検算が合わなかった時。控えから戻してから落ちる。"""
    print(f"NG: {msg}", file=sys.stderr)
    for t in targets:
        b = backup / t.name
        if b.exists():
            shutil.copy2(b, t)
            print(f"    控えから戻した: {t}", file=sys.stderr)
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
    header, blocks, raw = split_ledger(src)
    if header + "".join(b["text"] for b in blocks) != raw:
        die("台帳を塊に切って繋ぎ直すと元と違う", backup, [src])

    statuses = {s.strip() for s in args.statuses.split(",") if s.strip()}
    open_asked = statuses & OPEN_STATUSES
    if open_asked:
        print(
            f"NG: {sorted(open_asked)} は open である。--statuses では退避できない。"
            "どうしても退避するなら --ids で1本ずつ名指しすること。",
            file=sys.stderr,
        )
        sys.exit(2)
    ids = {i.strip() for i in args.ids.split(",") if i.strip()}
    keep_ids = {i.strip() for i in args.keep_ids.split(",") if i.strip()}

    move, keep = [], []
    for b in blocks:
        picked = (b["status"] in statuses or b["id"] in ids) and b["id"] not in keep_ids
        (move if picked else keep).append(b)
    if not move:
        print("退避する物が1件も無い。何も動かさずに終わる。")
        return

    dst = pathlib.Path(args.ledger_archive)
    if dst.exists():
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
    targets = [src, dst]
    _, keep2, _ = split_ledger(src)
    _, arc2, _ = split_ledger(dst)
    if len(keep2) + len(move) != len(blocks):
        die(f"件数が合わない: 残{len(keep2)} + 移{len(move)} ≠ 元{len(blocks)}", backup, targets)
    if {b["id"] for b in keep2} | {b["id"] for b in move} != {b["id"] for b in blocks}:
        die("id の集合が元と違う", backup, targets)
    dup = [k for k, v in collections.Counter(b["id"] for b in arc2).items() if v > 1]
    if dup:
        die(f"退避先に id の重複が増えた: {dup}", backup, targets)
    left_open = [b["id"] for b in blocks if b["status"] in OPEN_STATUSES]
    kept_ids = {b["id"] for b in keep2}
    missing = [i for i in left_open if i not in kept_ids]
    if missing:
        die(f"open なのに正本から消えた: {missing}", backup, targets)
    moved_text = {b["text"] for b in move}
    arc_text = {b["text"] for b in arc2}
    if not moved_text <= arc_text:
        die("移した塊が退避先に1文字も違わない形で入っていない", backup, targets)
    if not parses(src) or not parses(dst):
        die("退避の後の file が YAML として読めない", backup, targets)

    print(f"台帳 = {len(blocks)}本 → 正本 {len(keep2)}本 / 退避 {len(move)}本 ({dst})")
    print(f"    open {len(left_open)}本は全部 正本に在る。id の重複なし。両方 YAML として読める。")


def do_inbox(args, backup):
    arc_dir = pathlib.Path(args.inbox_archive)
    arc_dir.mkdir(parents=True, exist_ok=True)
    for p in sorted(pathlib.Path(args.inbox_dir).glob("*.yaml")):
        header, blocks, raw = split_inbox(p)
        if not blocks:
            continue
        if header + "".join(b["text"] for b in blocks) != raw:
            print(f"    飛ばす ({p.name} は塊に切ると元に戻らない)")
            continue
        unread_before = sum(1 for b in blocks if b["unread"])
        read_idx = [i for i, b in enumerate(blocks) if not b["unread"]]
        keep_read = set(read_idx[-args.keep_read :]) if args.keep_read else set()
        move = [b for i, b in enumerate(blocks) if not b["unread"] and i not in keep_read]
        keep = [b for b in blocks if b not in move]
        if not move:
            continue

        dst = arc_dir / p.name
        arc_before = (
            dst.read_text(encoding="utf-8")
            if dst.exists()
            else ARCHIVE_HEADER.format(
                name=p.name, stamp=args.stamp, reason="既読のみ (未読は1件も移さない)",
                approved=args.approved,
            ) + "messages:\n"
        )
        dst.write_text(arc_before + "".join(b["text"] for b in move), encoding="utf-8")
        p.write_text(header + "".join(b["text"] for b in keep), encoding="utf-8")

        targets = [p, dst]
        _, keep2, _ = split_inbox(p)
        _, arc2, _ = split_inbox(dst)
        if len(keep2) + len(move) != len(blocks):
            die(f"{p.name}: 件数が合わない", backup, targets)
        if sum(1 for b in keep2 if b["unread"]) != unread_before:
            die(f"{p.name}: ★未読が消えた★", backup, targets)
        if not {b["text"] for b in move} <= {b["text"] for b in arc2}:
            die(f"{p.name}: 移した塊が退避先に元のまま入っていない", backup, targets)
        if not parses(p) or not parses(dst):
            die(f"{p.name}: 退避の後の file が YAML として読めない", backup, targets)
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
