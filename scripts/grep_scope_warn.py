#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""grep_scope_warn.py — 再帰 grep が「追跡下しか見ておらぬ」ことを、その場で名乗らせる (cmd_1399)

■ 何が起きているか (実測・2026-07-27)
    この shell の `grep` は bash function で、中身は `ugrep --ignore-files` である。
    ゆえに .gitignore を尊ぶ。本リポジトリの .gitignore は白名簿型 (7 行目が `*`) ゆえ、
    queue/ plans/ logs/ dashboard.md 等の動的 file はほとんどが未追跡であり、
    ★`grep -rn ... .` の再帰から丸ごと消える★。

    実測:
      綴り subtask_karo_morning_sheet  … 再帰 grep 0 file / git ls-files 0 file / 全数走査 8 file
      "def " を含む .py               … 再帰 grep 24 本 / 全数走査 570 本 (.venv 抜きで 137 本)

    ★最も悪いのは、0 が「該当なし」と同じ顔で返ることである。★
    「探せていない 0」と「本当に無い 0」が区別できぬ。本日 家老が同じ夜に二度 踏んだ。

    ★但し 盲点の正体は【根の取り方】であった (本 cmd で判明・上記 blind_roots の註を見よ)★:
      grep -rl P .        → 0 本  (最上位の白名簿を読む = 盲)
      grep -rl P ./queue  → 6 本  (読まぬ = 全数と一致)
    ゆえに此の門は ★根に .gitignore が在る時だけ★ 口を開く。

■ 何をする道具か
    Claude Code の PostToolUse hook (matcher=Bash) として走る。
    打たれた command が「.gitignore を尊ぶ再帰検索」であった時にだけ口を開き、
    ★未追跡側を自分で検め直して、其の結果を数で名乗る★。

      ・未追跡側に当たりが在る  → 「追跡下では 0 でも、未追跡側に M 件 在る」と file 名つきで名指す
      ・未追跡側にも無い        → 「未追跡側 K 本も検めて 0 件」と名乗る  ← ★負の対照★
                                  之により 0 が二義でなくなる (見ておらぬ 0 が消える)

    ★落とさぬ★。既に走り終えた command の rc には触れぬ。名指すだけである。

■ 何をせぬか (射程を先に名乗る)
    ・作法を強制せぬ。禁じもせぬ。腐った時に気付かせるだけである。
    ・Claude CLI 以外 (codex/copilot/kimi/opencode) では走らぬ。hook は Claude Code の仕組ゆえ。
      2026-07-27 時点の config/settings.yaml は 10 体すべて type: claude ゆえ現況の覆いは 10/10。
      ★CLI を替えた体は黙って裸になる★ — 之は本道具では塞げぬ。
    ・`command grep` / `/usr/bin/grep` / `find | xargs grep` は元より全数を見るゆえ、口を開かぬ。

■ 経路
    grep_scope_warn.py                  # 引数なし + stdin JSON = PostToolUse hook
    grep_scope_warn.py --census         # 母数を数える (稿の数字を機械で出し直す口)
    grep_scope_warn.py --scan PATTERN   # 全数走査を人が明示で呼ぶ口
    grep_scope_warn.py --liveness       # 此の pane で現に走ったかを見る
    grep_scope_warn.py --selftest       # 己の牙が立っておるかを己で検める
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time

# ── 走査から外す木 ────────────────────────────────────────────────────────
# ★之は「見えなくてよい物」であって「見えぬ事に気付かねばならぬ物」ではない★。
#   外した本数は必ず数えて名乗る (黙って減らせば、また同じ病になる)。
NOISE_DIRS = (
    ".git/",
    ".venv/",
    "node_modules/",
    ".playwright-mcp/",
    "__pycache__/",
    ".pytest_cache/",
    ".ruff_cache/",
    ".mypy_cache/",
    "unsloth_compiled_cache/",
)

# .gitignore を尊ぶ検索器の名 (= 盲点を持つ側)。
# ★`command grep` と絶対 path 呼びは此処に入れぬ★ = 其れらは全数を見るゆえ警めては害になる。
IGNORE_AWARE = ("grep", "rg", "ugrep")

RECURSIVE_LONG = ("--recursive", "--dereference-recursive")
# 走査の上限 (WSL2 の /mnt/c は 1 file ≒ 1.5ms ゆえ、時間で切る)
DEADLINE_SEC = float(os.environ.get("GSW_DEADLINE", "12"))
MAX_NAMED = 5

HEARTBEAT = "logs/grep_scope_warn.heartbeat"


# ══════════════════════════════════════════════════════════════════════════
# 母数 — 「探せておらぬ file が今 何本 在るか」
# ══════════════════════════════════════════════════════════════════════════
def _is_noise(path: str) -> bool:
    for n in NOISE_DIRS:
        if path.startswith(n) or ("/" + n) in path:
            return True
    return False


def blind_files(root: str) -> tuple[list[str], int]:
    """未追跡ゆえ再帰 grep から消える file の一覧を返す。

    返り値 = (走査対象, 雑音として外した本数)
    ★git ls-files --others --ignored を使う理由★:
        `git ls-files` (追跡下) は再帰 grep と【同じ物を落とす】ゆえ母数にならぬ。
        家老の処方が持っていた盲点が之である。
    """
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "--others", "--ignored",
             "--exclude-standard", "-z"],
            capture_output=True, text=True, timeout=60,
        )
    except Exception:
        return [], 0
    if out.returncode != 0:
        return [], 0
    allp = [p for p in out.stdout.split("\0") if p]
    kept = [p for p in allp if not _is_noise(p)]
    return kept, len(allp) - len(kept)


# ══════════════════════════════════════════════════════════════════════════
# command の読み取り — 「之は .gitignore を尊ぶ再帰検索か」
# ══════════════════════════════════════════════════════════════════════════
class Search:
    def __init__(self, pattern: str, flags: list[str], fixed: bool,
                 roots: list[str] | None = None, git_grep: bool = False):
        self.pattern = pattern
        self.flags = flags      # /usr/bin/grep へ引き継ぐ flag
        self.fixed = fixed
        self.roots = roots or ["."]
        # ★git grep は【根に依らず】常に追跡下しか見ぬ★ (道具の定義そのもの)。
        #   ゆえに .gitignore の在処を見る判定を通さぬ (cmd_1399 の芯と同じ病を持つ道具である)。
        self.git_grep = git_grep


def _split_segments(command: str) -> list[list[str]] | None:
    """`;` `&&` `||` `|` で割り、各段を token 列にする。

    ★lex に失敗した時は None を返す (空 list ではない)★ — cmd_1425 と同じ族の直し。
    空 list を返すと呼ぶ側の for が一度も回らず、★一つも検めておらぬのに rc=0★ になる。
    「何も検めておらぬ」が「異常なし」の顔で返る形であり、本門が塞ごうとしている病そのものである。
    """
    try:
        lexer = shlex.shlex(command, posix=True)
        lexer.whitespace_split = True
        toks = list(lexer)
    except Exception:
        return None
    segs, cur = [], []
    for t in toks:
        if t in (";", "&&", "||", "|", "&"):
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


# 引き継ぐ flag (意味を変える物のみ。-r や -n は引き継がぬ)
_CARRY_SHORT = {"i", "w", "E", "F", "P", "x"}
_CARRY_LONG = ("--ignore-case", "--word-regexp", "--extended-regexp",
               "--fixed-strings", "--perl-regexp", "--line-regexp")


def parse_search(tokens: list[str]) -> Search | None:
    """token 列が「盲点を持つ再帰検索」なら Search を、違えば None を返す。"""
    if not tokens:
        return None
    # ★git grep は追跡下しか見ぬ = 家老を欺いたのと同じ病を持つ★ (家老 23:20 の裁)
    #   綴りが "git" ゆえ検索器の一覧に当たらず、之まで黙っていた。
    git_grep = False
    if tokens[0] == "git" and len(tokens) > 1 and tokens[1] == "grep":
        git_grep = True
        tokens = ["grep"] + tokens[2:]
    prog = tokens[0]
    # ★`command grep` / `/usr/bin/grep` / `\grep` は全数を見る = 警めぬ★
    if prog != os.path.basename(prog) or prog not in IGNORE_AWARE:
        return None

    recursive = False
    carried: list[str] = []
    pattern: str | None = None
    from_file = False
    roots: list[str] = []
    i = 1
    while i < len(tokens):
        t = tokens[i]
        if t == "--":
            i += 1
            while i < len(tokens):
                if pattern is None:
                    pattern = tokens[i]
                else:
                    roots.append(tokens[i])
                i += 1
            break
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            if name in RECURSIVE_LONG:
                recursive = True
            elif name in ("--regexp", "--pattern"):
                if "=" in t:
                    pattern = t.split("=", 1)[1]
                else:
                    i += 1
                    pattern = tokens[i] if i < len(tokens) else None
            elif name in ("--file",):
                from_file = True
            elif name in _CARRY_LONG:
                carried.append(t)
            elif name in ("--include", "--exclude", "--exclude-dir"):
                carried.append(t if "=" in t else t)
                if "=" not in t:
                    i += 1
                    if i < len(tokens):
                        carried.append(tokens[i])
        elif t.startswith("-") and len(t) > 1:
            body = t[1:]
            j = 0
            while j < len(body):
                c = body[j]
                if c in ("r", "R"):
                    recursive = True
                elif c in _CARRY_SHORT:
                    carried.append("-" + c)
                elif c == "e":
                    rest = body[j + 1:]
                    if rest:
                        pattern = rest
                    else:
                        i += 1
                        pattern = tokens[i] if i < len(tokens) else None
                    j = len(body)
                    break
                elif c == "f":
                    from_file = True
                    j = len(body)
                    break
                j += 1
        else:
            if pattern is None:
                pattern = t
            else:
                roots.append(t)
        i += 1

    if from_file or pattern is None:
        return None
    # ★rg / ugrep は【path を与えても】既定で再帰する★ (家老 23:20 の裁で直した)
    #   旧: `and not roots` が付いており、path を書くと再帰と読まなかった。
    #   ⇒ ★今 最も普通に打たれる `rg PAT .` が盲のまま黙っていた★ (軍師一号 23:1x の検分)。
    #   path が dir でなく file の時は blind_roots が dir か否かを見て弾くゆえ、之で騒ぎ過ぎぬ。
    if not recursive and prog in ("rg", "ugrep"):
        recursive = True
    # git grep は path の有無に依らず木を掃く
    if git_grep:
        recursive = True
    if not recursive:
        return None
    fixed = any(f in ("-F", "--fixed-strings") for f in carried)
    return Search(pattern, carried, fixed, roots or ["."], git_grep=git_grep)


# ══════════════════════════════════════════════════════════════════════════
# ★盲点は file の性質ではなく【何処を根に取ったか】の性質である★ (2026-07-27 実測)
#
#   ugrep --ignore-files が読むのは ★走査の根から下で出会った .gitignore だけ★ である。
#   ゆえに本 repo の白名簿 (最上位の .gitignore) が効くのは ★根が repo 直下の時だけ★。
#
#   実測 (綴り subtask_karo_morning_sheet):
#     grep -rl P .        → 0 本   ← 最上位 .gitignore を読む = 盲
#     grep -rl P ./queue  → 6 本   ← 読まぬ = 全数走査 (6 本) と一致
#     grep -rl P ./plans  → 1 本   ← 同上 (全数 1 本と一致)
#     cd queue && grep -rl P .  → 6 本 (根が queue ゆえ盲でない)
#
#   ⇒ ★「grep が未追跡を落とす」は言い過ぎであった。落とすのは根を repo 直下に置いた時である。★
#   ⇒ ゆえに此の門は ★根に .gitignore が在る時だけ★ 口を開く。
#     下位 dir を名指した検索まで警めれば狼少年になり、本物の赤が無視される。
# ══════════════════════════════════════════════════════════════════════════
def blind_roots(cwd: str, roots: list[str]) -> list[str]:
    """走査の根のうち、.gitignore を抱えておる物 (= 盲点が現に働く根) を返す。"""
    out = []
    for r in roots:
        base = r if os.path.isabs(r) else os.path.join(cwd, r)
        try:
            if os.path.isdir(base) and os.path.isfile(os.path.join(base, ".gitignore")):
                out.append(os.path.normpath(base))
        except Exception:
            continue
    return out


# ══════════════════════════════════════════════════════════════════════════
# 未追跡側を検め直す
# ══════════════════════════════════════════════════════════════════════════
def scan_blind(root: str, search: Search, files: list[str],
               deadline: float) -> tuple[list[str], int, bool]:
    """返り値 = (当たった file, 検めた本数, 時間切れか)"""
    hits: list[str] = []
    checked = 0
    batch = 200
    for k in range(0, len(files), batch):
        if time.monotonic() > deadline:
            return hits, checked, True
        chunk = files[k:k + batch]
        cmd = ["/usr/bin/grep", "-l", "-I"] + search.flags + ["-e", search.pattern, "--"] + chunk
        try:
            r = subprocess.run(cmd, cwd=root, capture_output=True, text=True,
                               timeout=max(1.0, deadline - time.monotonic()))
        except Exception:
            return hits, checked, True
        checked += len(chunk)
        if r.stdout:
            hits.extend([ln for ln in r.stdout.splitlines() if ln])
    return hits, checked, False


# ══════════════════════════════════════════════════════════════════════════
# hook 本体
# ══════════════════════════════════════════════════════════════════════════
def _observed_empty(payload: dict) -> bool | None:
    """打たれた command の出力が空であったか。判らねば None。"""
    resp = payload.get("tool_response")
    if resp is None:
        return None
    if isinstance(resp, str):
        return resp.strip() == ""
    if isinstance(resp, dict):
        for key in ("stdout", "output", "content", "result"):
            if key in resp and isinstance(resp[key], str):
                return resp[key].strip() == ""
    return None


def _beat(root: str) -> None:
    try:
        p = pathlib.Path(root) / HEARTBEAT
        p.parent.mkdir(parents=True, exist_ok=True)
        pane = os.environ.get("TMUX_PANE", "?")
        p.write_text(f"{int(time.time())} {pane}\n", encoding="utf-8")
    except Exception:
        pass


def build_message(root: str, search: Search, observed_empty: bool | None,
                  cwd: str | None = None) -> str | None:
    cwd = cwd or root
    if search.git_grep:
        # ★git grep は根に依らず追跡下しか見ぬ★ ゆえ .gitignore の在処を問わぬ
        blind = [os.path.normpath(root)]
    else:
        blind = blind_roots(cwd, search.roots)
    if not blind:
        # 根に .gitignore が無い = 此の検索は全数を見ておる = 口を開かぬ
        return None
    files, noise = blind_files(root)
    if not files:
        return None
    # 走査の根の下だけを勘定する (根が repo 直下でない時に数を盛らぬため)
    absroot = os.path.normpath(root)
    keep = []
    for f in files:
        fp = os.path.normpath(os.path.join(absroot, f))
        if any(fp == b or fp.startswith(b + os.sep) for b in blind):
            keep.append(f)
    files = keep
    if not files:
        return None
    hint = "根を下位 dir へ取れば見える (例: grep -rn PAT ./queue)"
    if search.git_grep:
        # 責めではなく報せである (家老 23:20 の指定)
        hint = "git grep は元より追跡下のみを見る道具である。" + hint
    # 追跡下に当たりが在ったと判っている時は、深い走査を省いて一行だけ名乗る。
    # (WSL2 の /mnt/c では全数走査が 5〜7 秒 かかる = 毎回 払う値ではない)
    if observed_empty is False:
        return (f"[grep_scope] 此の検索は根が .gitignore を抱えておるゆえ追跡下しか見ておらぬ。"
                f"未追跡 {len(files)} 本は未検である(雑音 {noise} 本を別勘定)。{hint}")

    deadline = time.monotonic() + DEADLINE_SEC
    hits, checked, timed_out = scan_blind(root, search, files, deadline)
    tail = "" if not timed_out else f" ★時間切れ = 残 {len(files) - checked} 本は未検★"
    if hits:
        named = "  ".join(hits[:MAX_NAMED])
        more = "" if len(hits) <= MAX_NAMED else f" 他 {len(hits) - MAX_NAMED} 本"
        return (f"[grep_scope] ★0 件は「無い」ではない★ — 未追跡側に {len(hits)} 本 当たった: "
                f"{named}{more} (検めた {checked}/{len(files)} 本・雑音 {noise} 本は別勘定){tail}。{hint}")
    return (f"[grep_scope] 負の対照 = 未追跡側 {checked} 本も検めて 0 件"
            f"(雑音 {noise} 本は別勘定){tail}。此の 0 は「探せておらぬ 0」ではない")


def run_hook(payload: dict) -> int:
    root = (payload.get("cwd")
            or os.environ.get("CLAUDE_PROJECT_DIR")
            or os.getcwd())
    tool = payload.get("tool_name") or ""
    if tool and tool != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        return 0
    _beat(root)

    segments = _split_segments(command)
    if segments is None:
        # ★lex に失敗した = 一つも検めておらぬ★。黙って rc=0 で返せば
        # 「何も検めておらぬ」が「異常なし」の顔になる (本門が塞ぐ病そのもの)。
        sys.stderr.write("[grep_scope] ★此の command を読めず、一つも検めておらぬ★ "
                         "(引用符が閉じておらぬ等)。0 件と出ても「無い」の証にはならぬ\n")
        return 2

    for seg in segments:
        search = parse_search(seg)
        if search is None:
            continue
        msg = build_message(root, search, _observed_empty(payload),
                            cwd=payload.get("cwd") or root)
        if msg:
            sys.stderr.write(msg + "\n")
            # PostToolUse の exit 2 = ★既に走った command の rc は変えず、言葉だけ返す★
            return 2
        return 0
    return 0


# ══════════════════════════════════════════════════════════════════════════
# 人が呼ぶ口
# ══════════════════════════════════════════════════════════════════════════
def cmd_census(root: str) -> int:
    files, noise = blind_files(root)
    tracked = subprocess.run(["git", "-C", root, "ls-files"],
                             capture_output=True, text=True).stdout.splitlines()
    print(f"追跡下 (再帰 grep が見る側)        : {len(tracked)} 本")
    print(f"未追跡・雑音を除く (見えぬ側)      : {len(files)} 本")
    print(f"未追跡・雑音として外した分         : {noise} 本")
    print("数え方: git ls-files --others --ignored --exclude-standard")
    print("        (git ls-files 単体は再帰 grep と同じ物を落とすゆえ母数にならぬ)")
    return 0


def cmd_scan(root: str, pattern: str, fixed: bool) -> int:
    files, noise = blind_files(root)
    search = Search(pattern, ["-F"] if fixed else [], fixed)
    hits, checked, timed_out = scan_blind(root, search, files,
                                          time.monotonic() + max(DEADLINE_SEC, 60))
    for h in hits:
        print(h)
    sys.stderr.write(f"[grep_scope --scan] 未追跡側 {checked}/{len(files)} 本を検め "
                     f"{len(hits)} 本 当たり (雑音 {noise} 本は別勘定)"
                     f"{' ★時間切れ★' if timed_out else ''}\n")
    return 0


def cmd_liveness(root: str) -> int:
    p = pathlib.Path(root) / HEARTBEAT
    if not p.exists():
        print("UNKNOWN: 心拍が無い = 此の木で一度も走っておらぬ")
        return 1
    try:
        raw = p.read_text(encoding="utf-8").split()
        age = int(time.time()) - int(raw[0])
    except Exception:
        print("UNKNOWN: 心拍が読めぬ")
        return 1
    print(f"last_beat_age_sec={age} pane={raw[1] if len(raw) > 1 else '?'}")
    return 0 if age < 3600 else 1


def cmd_selftest() -> int:
    """己の牙 — 判定の両側を撃つ。"""
    ng = []

    def check(name, cond):
        print(("ok   " if cond else "NG   ") + name)
        if not cond:
            ng.append(name)

    # 口を開くべき形
    check("S1 grep -rn pat . を再帰と読む",
          parse_search(["grep", "-rn", "foo", "."]) is not None)
    check("S2 grep -r --include=*.py -e pat . を再帰と読む",
          parse_search(["grep", "-r", "--include=*.py", "-e", "foo", "."]) is not None)
    check("S3 rg pat (path 省略) を再帰と読む",
          parse_search(["rg", "foo"]) is not None)
    # 口を開いてはならぬ形 (負の対照)
    check("S4 command grep -rn は全数を見るゆえ黙る",
          parse_search(["command", "grep", "-rn", "foo", "."]) is None)
    check("S5 /usr/bin/grep -rn は全数を見るゆえ黙る",
          parse_search(["/usr/bin/grep", "-rn", "foo", "."]) is None)
    check("S6 grep pat file (非再帰) は黙る",
          parse_search(["grep", "foo", "a.txt"]) is None)
    check("S7 grep -rf list . (pattern が file) は黙る",
          parse_search(["grep", "-rf", "list", "."]) is None)
    # flag の引き継ぎ
    s = parse_search(["grep", "-rniF", "foo", "."])
    check("S8 -i と -F を引き継ぐ",
          s is not None and "-i" in s.flags and "-F" in s.flags and s.fixed)
    check("S9 -n は引き継がぬ", s is not None and "-n" not in s.flags)
    # 雑音判定
    check("S10 .venv/ を雑音と読む", _is_noise(".venv/lib/x.py"))
    check("S11 plans/ を雑音と読まぬ", not _is_noise("plans/a.md"))
    # 根の読み取り (★盲点は根の性質★ — 之を誤ると狼少年になる)
    s2 = parse_search(["grep", "-rn", "foo", "./queue"])
    check("S12 根を token から拾う", s2 is not None and s2.roots == ["./queue"])
    s3 = parse_search(["grep", "-rn", "foo"])
    check("S13 根を省いたら . と読む", s3 is not None and s3.roots == ["."])
    # ★path を書いた rg / ugrep も再帰である★ (23:1x に軍師一号が名指した盲)
    check("S16 rg pat . を再帰と読む",
          parse_search(["rg", "foo", "."]) is not None)
    check("S17 ugrep pat . を再帰と読む",
          parse_search(["ugrep", "foo", "."]) is not None)
    check("S18 rg pat file (dir でない) も候補には上げる (dir か否かは根の側で見る)",
          parse_search(["rg", "foo", "a.txt"]) is not None)
    # ★git grep は追跡下しか見ぬ★
    s4 = parse_search(["git", "grep", "-n", "foo"])
    check("S19 git grep を盲と読む", s4 is not None and s4.git_grep)
    check("S20 git log は検索器でないゆえ黙る",
          parse_search(["git", "log", "--oneline"]) is None)
    # ★読めなんだ時は「空」でなく「読めぬ」を返す★
    check("S21 lex に失敗したら None (空 list を返さぬ)",
          _split_segments('grep -rn "unbalanced .') is None)
    check("S22 lex が通れば list を返す",
          isinstance(_split_segments('grep -rn foo .'), list))

    import tempfile
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "sub"))
        open(os.path.join(td, ".gitignore"), "w").close()
        check("S14 .gitignore を抱えた根は盲と読む",
              blind_roots(td, ["."]) == [os.path.normpath(td)])
        check("S15 .gitignore を持たぬ下位 dir は盲と読まぬ",
              blind_roots(td, ["sub"]) == [])

    print(("SELFTEST PASS" if not ng else f"SELFTEST FAIL ({len(ng)})"))
    return 0 if not ng else 1


def main(argv: list[str]) -> int:
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if argv and argv[0] == "--census":
        return cmd_census(root)
    if argv and argv[0] == "--liveness":
        return cmd_liveness(root)
    if argv and argv[0] == "--selftest":
        return cmd_selftest()
    if argv and argv[0] == "--scan":
        if len(argv) < 2:
            sys.stderr.write("usage: --scan PATTERN [--fixed]\n")
            return 1
        return cmd_scan(root, argv[1], "--fixed" in argv[2:])
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # fail-OPEN (loud) — 門の不調で書き手を止めぬ。但し黙らぬ。
        sys.stderr.write("[grep_scope] stdin JSON を読めず (素通し)\n")
        return 0
    try:
        return run_hook(payload)
    except Exception as exc:  # fail-OPEN (loud)
        sys.stderr.write(f"[grep_scope] 内部異常ゆえ素通し: {type(exc).__name__}: {exc}\n")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
