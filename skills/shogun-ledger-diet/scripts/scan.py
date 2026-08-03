#!/usr/bin/env python3
"""台帳と inbox を塊に切り、状態ごとの件数を出す (読むだけ・1文字も書かない)。

これは「承認を得るために人へ見せる」ための出力である。常時 測るための計器ではない。
"""
import argparse
import collections
import pathlib
import sys

OPEN_STATUSES = {"pending", "in_progress"}


def split_ledger(path):
    """台帳を「- id:」で始まる塊に切る。塊のテキストは1文字も変えない。"""
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines(keepends=True)
    starts = [i for i, l in enumerate(lines) if l.startswith("- id:")]
    if not starts:
        return raw, [], raw
    header = "".join(lines[: starts[0]])
    blocks = []
    for n, i in enumerate(starts):
        j = starts[n + 1] if n + 1 < len(starts) else len(lines)
        status = None
        for l in lines[i:j]:
            if l.startswith("  status:"):
                status = l.split(":", 1)[1].split("#")[0].strip()
                break
        blocks.append(
            {
                "id": lines[i].split(":", 1)[1].strip(),
                "status": status,
                "text": "".join(lines[i:j]),
            }
        )
    return header, blocks, raw


def split_inbox(path):
    """inbox を「- content:」で始まる塊に切る。"""
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines(keepends=True)
    starts = [i for i, l in enumerate(lines) if l.startswith("- content:")]
    if not starts:
        return raw, [], raw
    header = "".join(lines[: starts[0]])
    blocks = []
    for n, i in enumerate(starts):
        j = starts[n + 1] if n + 1 < len(starts) else len(lines)
        chunk = lines[i:j]
        unread = any(l.startswith("  read: false") for l in chunk)
        mid = ""
        for l in chunk:
            if l.startswith("  id:"):
                mid = l.split(":", 1)[1].strip()
                break
        blocks.append({"id": mid, "unread": unread, "text": "".join(chunk)})
    return header, blocks, raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ledger", default="queue/shogun_to_karo.yaml")
    ap.add_argument("--inbox-dir", default="queue/inbox")
    ap.add_argument("--keep-read", type=int, default=5, help="inbox で残す既読の件数")
    args = ap.parse_args()

    ledger = pathlib.Path(args.ledger)
    header, blocks, raw = split_ledger(ledger)

    # 切って繋ぎ直したら元に戻るか。戻らないなら以後の手順は撃てない。
    if header + "".join(b["text"] for b in blocks) != raw:
        print("NG: 台帳を塊に切って繋ぎ直すと元と違う。この skill は撃てない。", file=sys.stderr)
        return 2

    print(f"■ 台帳 {ledger} = {len(raw.splitlines())}行 / cmd {len(blocks)}本")
    counts = collections.Counter(b["status"] for b in blocks)
    for status, n in counts.most_common():
        mark = "  ← open (退避しない)" if status in OPEN_STATUSES else ""
        print(f"    {n:4d}  {status}{mark}")
    dup = [k for k, v in collections.Counter(b["id"] for b in blocks).items() if v > 1]
    print(f"    id の重複: {dup if dup else 'なし'}")

    print("\n  状態ごとの id:")
    for status, _ in counts.most_common():
        ids = [b["id"] for b in blocks if b["status"] == status]
        print(f"    {status}: {' '.join(ids)}")

    print(f"\n■ inbox {args.inbox_dir} (未読は全部 残す / 既読は直近 {args.keep_read} 件を残す)")
    total_e = total_u = total_move = 0
    for p in sorted(pathlib.Path(args.inbox_dir).glob("*.yaml")):
        ihdr, iblocks, iraw = split_inbox(p)
        if ihdr + "".join(b["text"] for b in iblocks) != iraw:
            print(f"    NG: {p.name} は塊に切ると元に戻らない。この file は触らないこと。")
            continue
        unread = sum(1 for b in iblocks if b["unread"])
        read_idx = [i for i, b in enumerate(iblocks) if not b["unread"]]
        keep_read = set(read_idx[-args.keep_read :]) if args.keep_read else set()
        move = [i for i in read_idx if i not in keep_read]
        total_e += len(iblocks)
        total_u += unread
        total_move += len(move)
        if iblocks:
            print(
                f"    {p.name:16s} 全{len(iblocks):3d}件  未読{unread:3d}  "
                f"退避の案{len(move):3d}  残す{len(iblocks) - len(move):3d}"
            )
    print(f"    合計 = 全{total_e}件 / 未読{total_u}件 / 退避の案{total_move}件")

    print("\n★ここで止まる。件数と案を人へ見せ、承認を得るまで1件も動かさない。★")
    return 0


if __name__ == "__main__":
    sys.exit(main())
