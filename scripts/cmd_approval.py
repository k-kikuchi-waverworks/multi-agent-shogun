#!/usr/bin/env python3
"""cmd_approval.py — 台帳の cmd へ「自己修正か」と「承認の状態」を書き込む (cmd_1475)

殿のご下命 (2026-07-28 20:0x):
  「自己修正タスクも automate-engine に掲載されてるようにしておいて
    (自己修正というラベルを付与するなどして分かりやすくして)」

■ 何ゆえ欄が要るか
19:21 に「自己修正は禁止。cmd を起票し、殿の承認を得てから着手する」と決まった。
殿が承認なさる場所 = engine の backlog 画面である。ところが台帳には
「その cmd が自己修正か」を判じられる欄が無く、画面も出しようが無かった。
推測で判定させると、殿が誤った物を承認なさる。ゆえに起票時に明示する欄を持たせる。

■ 足す欄は 2 つ (どちらも省いてよい = 省けば「未記入」)
  self_repair: true    この仕組み (multi-agent-shogun) 自身の改修。殿の承認が要る
  self_repair: false   殿の指令そのもの。承認は要らない
  approval: awaiting   承認待ち  (self_repair: true の時だけ意味を持つ)
  approval: approved   承認済み
  approval: rejected   却下

■ 何ゆえ手で書かずにこの script を通すか
台帳を手で編集して壊す事故が現に起きている (2026-07-28 19:04 = 守りが正しい台帳を
壊れたと判じて巻き戻した)。この script は書いた後に必ず検め、通らなければ元へ戻す。
書き方も「その行だけ差し替える」形で、他の行には 1 バイトも触らない。

■ 使い方
  python3 scripts/cmd_approval.py --cmd cmd_1462 --self-repair true --approval awaiting
  python3 scripts/cmd_approval.py --cmd cmd_1462 --approval approved
  python3 scripts/cmd_approval.py --selftest      # 自分で自分を検める (陽性 + 陰性)

exit: 0=書けた / 1=書けず元へ戻した / 2=呼び方が誤っている
"""
import argparse
import errno
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LEDGER = os.path.join(REPO, "queue", "shogun_to_karo.yaml")
VALIDATOR = os.path.join(REPO, "scripts", "ledger_validate.py")

SELF_REPAIR_VALUES = ("true", "false")
APPROVAL_VALUES = ("awaiting", "approved", "rejected")
LOCK_TIMEOUT_SEC = 30

# entry の先頭行。cmd_id_alloc.sh が書く形 (`- id: cmd_1475`) に合わせる。
ENTRY_HEAD_RE = re.compile(r"^-\s+(id|cmd_id):\s*['\"]?(cmd_\d+)['\"]?\s*$")
# entry 直下の欄 (indent 2)。block scalar の中身は indent 4 以上ゆえ当たらない。
FIELD_RE = re.compile(r"^  (\w+):")


def die(msg, code=2):
    print(f"[cmd_approval] ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def log(msg):
    print(f"[cmd_approval] {msg}", file=sys.stderr)


class Lock:
    """cmd_id_alloc.sh と同じ錠 (mkdir + flock) を取る。

    同じ錠を使わないと、採番の追記とこの書き替えが同時に走った時に
    片方の書いた分が消える。錠の名前は cmd_id_alloc.sh と 1 文字も違えてはならない。
    """

    def __init__(self, ledger):
        self.lockfile = ledger + ".lock"
        self.lockdir = self.lockfile + ".d"
        self.fh = None

    def __enter__(self):
        deadline = time.time() + LOCK_TIMEOUT_SEC
        while True:
            try:
                os.mkdir(self.lockdir)
                break
            except OSError as e:
                if e.errno != errno.EEXIST:
                    raise
                if time.time() >= deadline:
                    die(f"錠を取れぬ ({self.lockdir} が残っているなら手で消せ)", 1)
                time.sleep(0.1)
        try:
            import fcntl

            self.fh = open(self.lockfile, "w")
            fcntl.flock(self.fh, fcntl.LOCK_EX)
        except ImportError:
            pass
        return self

    def __exit__(self, *exc):
        if self.fh is not None:
            try:
                import fcntl

                fcntl.flock(self.fh, fcntl.LOCK_UN)
            except ImportError:
                pass
            self.fh.close()
        try:
            os.rmdir(self.lockdir)
        except OSError:
            pass
        return False


def find_entry(lines, cmd_id):
    """cmd_id の entry が占める行の範囲 [開始, 終了) を返す。無ければ None。

    終了 = 次の entry の先頭行。最後の entry なら file の末尾。
    """
    start = None
    for i, line in enumerate(lines):
        m = ENTRY_HEAD_RE.match(line)
        if not m:
            continue
        if start is not None:
            return (start, i)
        if m.group(2) == cmd_id and m.group(1) == "id":
            start = i
    if start is not None:
        return (start, len(lines))
    return None


def apply_fields(lines, span, fields):
    """entry の中の欄を差し替える。無ければ id 行の直後へ足す。他の行は触らない。"""
    start, end = span
    out = list(lines)
    for key, value in fields.items():
        line = f"  {key}: {value}\n"
        hit = None
        for i in range(start + 1, min(end, len(out))):
            m = FIELD_RE.match(out[i])
            if m and m.group(1) == key:
                hit = i
                break
        if hit is not None:
            out[hit] = line
        else:
            out.insert(start + 1, line)
            end += 1
    return out


def load_entries(path):
    import yaml

    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    cmds = doc.get("commands") if isinstance(doc, dict) else None
    if not isinstance(cmds, list):
        return None
    return cmds


def validate(path):
    r = subprocess.run(
        [sys.executable, VALIDATOR, path], capture_output=True, text=True
    )
    return r.returncode == 0, (r.stderr or "").strip()


def diff_only_target(before, after, cmd_id, fields):
    """狙った entry の狙った欄だけが動いたことを確かめる。

    「書けた」と「正しく書けた」は別ゆえ、書いた後に自分で読み直して照らす。
    """
    if before is None or after is None:
        return "台帳を読み直せぬ (parse 不能)"
    if len(before) != len(after):
        return f"entry 数が動いた ({len(before)} → {len(after)})"
    for b, a in zip(before, after):
        if not isinstance(b, dict) or not isinstance(a, dict):
            if b != a:
                return "mapping でない要素が動いた"
            continue
        if b.get("id") == cmd_id:
            for k, v in fields.items():
                got = a.get(k)
                want = True if v == "true" else False if v == "false" else v
                if got != want:
                    return f"{cmd_id} の {k} が {want!r} にならず {got!r} である"
            for k in set(b) | set(a):
                if k in fields:
                    continue
                if b.get(k) != a.get(k):
                    return f"{cmd_id} の {k} が意図せず動いた"
        elif b != a:
            return f"他の entry ({b.get('id')}) が動いた"
    return None


def write_fields(ledger, cmd_id, fields, quiet=False):
    """1 entry へ欄を書く。検めに落ちたら元へ戻して 1 を返す。"""
    if not os.path.isfile(ledger):
        die(f"台帳が無い: {ledger}")

    with Lock(ledger):
        with open(ledger, encoding="utf-8", newline="") as f:
            original = f.read()
        lines = original.splitlines(keepends=True)
        span = find_entry(lines, cmd_id)
        if span is None:
            die(f"{cmd_id} が台帳に無い ({ledger})。id を確かめよ")

        before = load_entries(ledger)
        new_lines = apply_fields(lines, span, fields)
        if "".join(new_lines) == original:
            if not quiet:
                log(f"{cmd_id}: 既に同じ値ゆえ 1 バイトも書かなかった")
            return 0

        snap = tempfile.NamedTemporaryFile(
            prefix="cmd_approval_snap_", suffix=".yaml", delete=False
        ).name
        shutil.copy2(ledger, snap)

        # 一時 file へ書いてから置き換える (途中で落ちても半端な台帳が残らない)
        tmp_fd, tmp = tempfile.mkstemp(
            prefix=".cmd_approval_", dir=os.path.dirname(ledger)
        )
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8", newline="") as f:
                f.write("".join(new_lines))
            shutil.copymode(ledger, tmp)
            os.replace(tmp, ledger)
        except Exception:
            os.path.exists(tmp) and os.unlink(tmp)
            os.unlink(snap)
            raise

        ok, err = validate(ledger)
        problem = None if ok else f"ledger_validate FAIL: {err}"
        if problem is None:
            problem = diff_only_target(before, load_entries(ledger), cmd_id, fields)

        if problem is not None:
            shutil.copy2(snap, ledger)
            os.unlink(snap)
            log(f"{cmd_id}: 書いた分を元へ戻した — {problem}")
            return 1

        os.unlink(snap)
        if not quiet:
            log(f"{cmd_id}: {fields} を書いた (検め通過)")
        return 0


# ---------------------------------------------------------------------------
# 自分で自分を検める (陽性と陰性の両方を撃つ)
# ---------------------------------------------------------------------------

FIXTURE = """commands:
- id: cmd_0001
  title: |
    先頭の entry
  origin: karo
  status: pending
  evidence: |
    自由文の中に - id: cmd_9999 と書いてあっても entry の頭と読まぬこと
- id: cmd_0002
  title: |
    真ん中の entry (既に欄を持つ)
  self_repair: false
  approval: awaiting
  status: deferred
- cmd_id: cmd_0001
  progress: legacy 形 (id でなく cmd_id) は entry の頭として扱わぬ
- id: cmd_0003
  title: |
    最後の entry
  status: in_progress
"""


def selftest():
    import yaml

    fails = []

    def check(name, cond, detail=""):
        print(f"  {'ok  ' if cond else 'FAIL'} {name}{'' if cond else ' — ' + detail}")
        if not cond:
            fails.append(name)

    workdir = tempfile.mkdtemp(prefix="cmd_approval_selftest_")
    ledger = os.path.join(workdir, "ledger.yaml")

    def reset():
        with open(ledger, "w", encoding="utf-8", newline="") as f:
            f.write(FIXTURE)

    def entries():
        with open(ledger, encoding="utf-8") as f:
            return yaml.safe_load(f)["commands"]

    def by_id(cid):
        return next(c for c in entries() if c.get("id") == cid)

    print("[cmd_approval] selftest — 陽性 (書けること)")
    reset()
    rc = write_fields(
        ledger, "cmd_0001", {"self_repair": "true", "approval": "awaiting"}, quiet=True
    )
    check("欄の無い entry へ足せる", rc == 0 and by_id("cmd_0001").get("self_repair") is True)
    check("承認の状態も入る", by_id("cmd_0001").get("approval") == "awaiting")
    check("他の entry は動かぬ", by_id("cmd_0003").get("status") == "in_progress")
    check("entry の数は変わらぬ", len(entries()) == 4, f"{len(entries())} 件")

    reset()
    write_fields(ledger, "cmd_0002", {"approval": "approved"}, quiet=True)
    e = by_id("cmd_0002")
    check("既に在る欄は差し替わる", e.get("approval") == "approved")
    check("差し替えても隣の欄は残る", e.get("self_repair") is False and e.get("status") == "deferred")
    with open(ledger, encoding="utf-8") as f:
        body = f.read()
    check("同じ欄が二重に増えぬ", body.count("  approval:") == 1, f"{body.count('  approval:')} 行")

    reset()
    write_fields(ledger, "cmd_0002", {"approval": "awaiting"}, quiet=True)
    with open(ledger, encoding="utf-8") as f:
        same = f.read()
    check("同じ値なら 1 バイトも書かぬ", same == FIXTURE)

    reset()
    write_fields(ledger, "cmd_0003", {"self_repair": "true"}, quiet=True)
    check("最後の entry にも書ける", by_id("cmd_0003").get("self_repair") is True)

    print("[cmd_approval] selftest — 陰性 (壊れた時に止まること)")
    reset()
    # 自由文の中の「- id: cmd_9999」を entry の頭と読んだら、ここで書けてしまう
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--cmd", "cmd_9999",
         "--self-repair", "true", "--ledger", ledger],
        capture_output=True, text=True,
    )
    with open(ledger, encoding="utf-8") as f:
        after = f.read()
    check("台帳に無い id は撥ねる", proc.returncode == 2, f"rc={proc.returncode}")
    check("撥ねた時は 1 バイトも動かぬ", after == FIXTURE)

    for bad, kind in (("maybe", "--approval"), ("yes", "--self-repair")):
        proc = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--cmd", "cmd_0001",
             kind, bad, "--ledger", ledger],
            capture_output=True, text=True,
        )
        check(f"{kind} の値 {bad!r} は撥ねる", proc.returncode == 2, f"rc={proc.returncode}")

    # 検めが落ちる形 = 書いた後に台帳が壊れていると分かった時、元へ戻せるか。
    # validator を必ず落ちる物へ差し替えて撃つ (書き込み自体は現に成功する経路を通す)。
    reset()
    global VALIDATOR
    keep = VALIDATOR
    broken = os.path.join(workdir, "always_fail.py")
    with open(broken, "w", encoding="utf-8") as f:
        f.write("import sys\nprint('FAIL: 試験用', file=sys.stderr)\nsys.exit(1)\n")
    VALIDATOR = broken
    rc = write_fields(ledger, "cmd_0001", {"self_repair": "true"}, quiet=True)
    VALIDATOR = keep
    with open(ledger, encoding="utf-8") as f:
        after = f.read()
    check("検めに落ちたら 1 を返す", rc == 1, f"rc={rc}")
    check("検めに落ちたら元へ戻る", after == FIXTURE)

    # 陰性の陰性 = 上の 2 本が「常に緑」でないこと。
    # 検めを通す validator に戻せば、同じ撃ち方で現に書けねばならない。
    reset()
    rc = write_fields(ledger, "cmd_0001", {"self_repair": "true"}, quiet=True)
    check("検めが通る時は現に書ける (上の陰性が空振りでない証)",
          rc == 0 and by_id("cmd_0001").get("self_repair") is True)

    shutil.rmtree(workdir, ignore_errors=True)
    print(f"[cmd_approval] selftest: {'PASS' if not fails else 'FAIL ' + ', '.join(fails)}")
    return 0 if not fails else 1


def main():
    p = argparse.ArgumentParser(add_help=True, description=__doc__)
    p.add_argument("--cmd", help="対象の cmd id (例 cmd_1462)")
    p.add_argument("--self-repair", choices=SELF_REPAIR_VALUES,
                   help="true=この仕組み自身の改修 / false=殿の指令")
    p.add_argument("--approval", choices=APPROVAL_VALUES,
                   help="awaiting=承認待ち / approved=承認済み / rejected=却下")
    p.add_argument("--ledger", default=DEFAULT_LEDGER)
    p.add_argument("--selftest", action="store_true", help="自分で自分を検める")
    args = p.parse_args()

    if args.selftest:
        sys.exit(selftest())
    if not args.cmd:
        die("--cmd が要る (--selftest で自己検査)")
    if not args.self_repair and not args.approval:
        die("--self-repair か --approval のどちらかが要る")

    fields = {}
    if args.self_repair:
        fields["self_repair"] = args.self_repair
    if args.approval:
        fields["approval"] = args.approval
    sys.exit(write_fields(args.ledger, args.cmd, fields))


if __name__ == "__main__":
    main()
