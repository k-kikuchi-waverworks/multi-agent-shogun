#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""process_signal_guard.py — ★「process を殺す力」そのものを禁ずる関所★ (cmd_1411)

★★配線されておる (今)★★ = 本 script は現に走っており、効力を持つ。
  ・どこから  : .claude/settings.json → hooks.PreToolUse[matcher="Bash"] の 2 本目
                (1 本目は shell_expansion_guard.py)。timeout 10 秒。
  ・いつから  : 2026-07-27 12:30:14 JST / commit 57272a9 (cmd_1411)。
                同じ commit で permissions.deny の Bash(kill *) / Bash(killall *) 2 行を落としておる
                (deny は hook より強いゆえ、残せば kill -0 が拒まれ続ける)。
  ・効いておる証 (実戦): 2026-07-28 02:0x、足軽六号が古い走行を止めようとして本 guard に拒まれた。
  ★ゆえに本 file を触る者は「置いてあるだけ」と読むな。書き替えれば全 agent の Bash が即座に影響を受ける。★

  ──── 以下は 2026-07-27 10:20〜12:30 の間だけ真であった旧記述 (経緯として残す) ────
  「★★未配線である★★ = 本 script は settings.json から呼ばれておらぬ (2026-07-27 時点)。
    ★殿の禁を【緩める向き】の変更を含むゆえ、軍師の検分を経てから当てる★ (殿の枷③)。
    配線せぬ限り本 file は一切の効力を持たぬ = 置いてあるだけでは何も塞がぬし、何も通さぬ。」
  = 起草時 (commit 3459e60・足軽二号) の状態である。殿の枷③ (軍師の検分を経てから当てよ) は
    軍師一号の条件つき PASS で満たされ、家老の命で 12:30 に配線された。
  ★而して頭書は 12:30 に直されず、約 14 時間 嘘を名乗り続けた (cmd_1438 で是正)★。

──────────────────────────────────────────────────────────────────────────
★なぜ綴りの禁では足りぬのか (cmd_1411 の起源・全て実測)★
──────────────────────────────────────────────────────────────────────────
  旧 = settings.json の permissions.deny に `Bash(kill *)` / `Bash(killall *)` の二行。
  ★之が答えておる問い★ = ★「其の文字列は kill で始まるか」★
  ★我らが答えておると思うておった問い★ = ★「其れは process へ信号を送るか」★
  ★二つは別の問いである★ ⇒ 実測で四方に破れておった:

    (1) ★通ってはならぬ物が通る★
        ・`pkill -0 -f '<綴り>'`      → ★通った★ (禁に pkill の三文字が無い)
        ・`/bin/kill -0 $$`            → ★通った★ (絶対 path は `kill *` の頭に当たらぬ)
        ・`/usr/bin/killall --version` → ★通った★ (同上)
        ・`fuser` / `skill` / `xkill` / `taskkill.exe` → ★禁に一度も現れぬ★ (本機に四つとも実在)
    (2) ★通ってよい物が止まる★
        ・`kill -0 $$`          → ★拒まれた★ = ★何も殺さぬ生存確認★が止まる
        ・`killall --help`      → ★拒まれた★ = ★signal を一切送らぬ help 表示★が止まる
        ⇒ ★之が四号・家老の手を縛り、殿の手番 (A-4) を生んだ★。

  ★止めが六号の一手★ = 本朝 現に `pkill -f` を使うた = ★我らの agent が
  【自然に手を伸ばす先】が、禁の一度も届かぬ場所であった★。
  ★而も repo は之を既に知っておった★ =
    scripts/gpu_sidecar_stop.sh の註「★但し pkill で迂回するのは【黙って通る道】
    そのものゆえ禁★」(★行番号で指さぬ★ = 行が動けば別の物を指すゆえ・条F。
    上の逐語そのもので探せる)
  ⇒ ★知は散文で在り、機械の側に無かった★ = 本夜ずっと潰してきた族の、最も素直な形。

──────────────────────────────────────────────────────────────────────────
★判定の芯 = 綴りでなく【力】を見る★
──────────────────────────────────────────────────────────────────────────
  R1 ★command 位置に在る語だけを見る★
     = 引用の中・grep の綴り・heredoc の本文に在る "kill" は ★力ではなく字である★。
     ★之を撃たぬ理由は実測で立つ★: 本 guard が字まで見れば、本 cmd の調査で
     拙者自身が撃った走査 command が悉く止まる (詳細は plans/cmd_1411_deny_by_capability.md)。
     ★塞ぎ過ぎた禁は外される★ (家老の枷(6)・cmd_1388 の族)。
  R2 ★signal 0 は通す★
     = signal 0 は ★何も殺さぬ★。「其の pid は生きておるか」を問うだけである。
     ★之が殿の A-5 の眼目★ = 力で禁じ、力を持たぬ物は通す。
  R3 ★signal を送らぬ副機能は通す★ = `-l` (signal 一覧) / `--help` / `--version`。
  R4 ★解けぬ時、signal 送出の疑いが在るなら拒む (狭い fail-CLOSED)★
     = 疑いが無ければ通す (広い fail-OPEN)。★理由は下の「二段の倒し方」に記す★。

──────────────────────────────────────────────────────────────────────────
★二段の倒し方 (既存の shell_expansion_guard と態度を違える理由)★
──────────────────────────────────────────────────────────────────────────
  shell_expansion_guard は ★fail-OPEN★ である。其れは正しい =
    彼の guard が誤って落ちても、失われるのは ★本文の忠実さ★ だけゆえ。
  ★本 guard は違う★ = 落ちれば ★殿の process が死ぬ★。
  ★然れど全面 fail-CLOSED も採らぬ★ = 内部異常のたび全 agent の Bash が止まれば、
    其の禁は外される (家老の枷(6))。
  ⇒ ★二段に倒す★:
      ・raw 文字列に signal 送出語の気配すら無い → ★通す★ (fail-OPEN・loud)
      ・気配が在るのに解けなんだ           → ★拒む★ (fail-CLOSED・理由を名乗る)
    ★之なら「常に鳴る禁」にならず、且つ危うい側で黙らぬ★。
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys

# ★tokenizer は既存の関所から借りる★ = ★物差しを二本 持たぬため★。
#   引用状態を保った分割は shell_expansion_guard が既に解いておる。同じ木に二つの
#   tokenizer が居れば、黙って食い違う日が来る (本 repo が繰り返し踏んだ族ゆえ)。
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
_TOKENIZER_ERR: Exception | None = None
try:
    from shell_expansion_guard import mask_heredoc_bodies, tokenize  # type: ignore
    _TOKENIZER_OK = True
except Exception as _exc:  # 借り手が壊れておっても本 guard は判断を続ける
    _TOKENIZER_OK = False
    _TOKENIZER_ERR = _exc

# ★★退化を黙って起こさぬ (cmd_1411 (b)・軍師一号の実測より)★★
#   ★軍師一号 09:5x = 之を現に踏んだ★= ★兄弟 (shell_expansion_guard) を欠いた盤面で
#   selftest 34/62・NG 28 = ★過剰に拒む 24 / 見落とす 4★★
#   ⇒ ★★此の門は import が壊れた時【盲になる】のではなく【喧しくなる】★★
#   ⇒ ★喧しさの出所が判らねば、手は「禁を外す」へ向く (cmd_1388 の族 = 塞ぎ過ぎた禁は外される)★
#   ⇒ ★ゆえに【退化して走っておる事】を、判定の前に一行 名乗る★
#     = ★★手を「import を直す」へ向けるための一行である★★。
#   ★鳴る条件を狭く縛る★= ★健全な時は一言も出さぬ★ (常に鳴る門を作らぬ・cmd_1388)。
_DEGRADED_BANNER = (
    "[process_signal_guard] ★退化して走っておる★: tokenizer の借り先 "
    "(scripts/shell_expansion_guard.py) を読めなんだ ({err}) — "
    "★過剰に拒む側へ倒れる (実測 62 件中 NG 28 = 過剰 24 / 見落とし 4)★ = "
    "★★之は禁が辛いのではない。直す先は import であって禁ではない★★"
)


def degraded_banner() -> str | None:
    """★退化しておる時のみ一行を返す。健全なら None★ (試験が両側を撃てる形にしておく)"""
    if _TOKENIZER_OK:
        return None
    return _DEGRADED_BANNER.format(err=_TOKENIZER_ERR)


# ══════════════════════════════════════════════════════════════════════════
# 力の目録 — ★「走っておる process へ signal を送れる物」だけを載せる★
# ══════════════════════════════════════════════════════════════════════════
#   ★pgrep を載せておらぬのは意図である★ = pgrep は ★問うだけで送らぬ★。
#   ★agent は pgrep を日々使う★ ゆえ、之を巻き込めば其の禁は外される。
SIGNAL_SENDERS = {
    "kill",           # shell builtin + /bin/kill + /usr/bin/kill (三つとも本機に実在)
    "pkill",
    "killall",
    "skill",          # SysV。本機に /usr/bin/skill として実在
    "xkill",          # X client を殺す。無害な形を持たぬ
    "fuser",          # ★-k を伴う時のみ殺す★ (伴わねば報告するだけ)
    "taskkill",       # Windows
    "taskkill.exe",
}

# ★二語で殺す物★ (cmd_1411 裁(2)・家老 10:26 の命で射程へ足した)
#   ★実績は 0 件★ (72,655 command を command 位置で数えた) ★而して害が重い★ =
#   ★pane を殺せば其処に居る agent の process ごと死ぬ★ ⇒ ★実績の薄さは通す理由にならぬ★。
#   ★無害な形を持たぬ★ = signal 0 に当たる物が tmux の kill-pane には無い ⇒ 常に拒む。
#   ★kill-server / kill-session は deny の 2 行が今も持つ★ (本案は其の 2 行に触れぬ) ゆえ此処には載せぬ。
#   ★canary★= 数え方が生きておることは tmux kill-server を 6 件 拾えた事で示した。
TWO_WORD_KILLERS = {
    ("tmux", "kill-pane"),
    ("tmux", "kill-window"),
}

# ★通り抜けの語★ = 之ら自身は殺さぬが、後ろの語へ力を渡す。
#   ⇒ ★頭から剥がして、真の command を見に行く★。
#   実測: `env kill -0 $$` は旧禁が拒み、`echo $$ | xargs kill -0` も拒んだ =
#   ★旧禁は segment 分割まではしておった★。之を落とさぬよう同じ深さで剥がす。
WRAPPERS = {
    "env", "command", "builtin", "exec", "nohup", "setsid", "stdbuf",
    "nice", "ionice", "time", "xargs", "sudo", "doas", "watch", "timeout",
}

# 之ら wrapper のうち、★flag でない引数を1つ食う★ 物 (剥がす時に読み飛ばす)
WRAPPER_EATS_ONE_ARG = {"timeout", "nice", "ionice", "watch"}

# signal を一切送らぬ副機能
INERT_FLAGS = {"-l", "-L", "--list", "--table", "--help", "-h", "--version", "-V", "/?"}

# raw 文字列に此の気配が在れば「解けぬ時は拒む」側へ倒す (R4)
_SUSPECT_RE = re.compile(
    r"(?<![-\w.])(kill|pkill|killall|skill|xkill|fuser|taskkill)(?![-\w.])", re.I
)

_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_NUMERIC_SIGNAL_RE = re.compile(r"^-(\d+)$")
_NAMED_SIGNAL_RE = re.compile(r"^-(?:SIG)?([A-Z][A-Z0-9]+)$", re.I)


class Finding(dict):
    pass


def _basename(word: str) -> str:
    return word.rsplit("/", 1)[-1]


def strip_comments(command: str) -> str:
    r"""★引用の外に在る `#` 以降を行末まで落とす★

    ★之も実測で出た穴である (cmd_1411)★ = 案の門を ★我らが現に撃った 72,570 件★ へ
    当てた所、DENY 121 件のうち ★2 件が誤検知★ であった。両方とも同じ形:

        # backlog_state.yaml 更新(skill Step 4)   ← ★註釈の中の「skill」★

    `(` を tokenize が operator として割るゆえ ★`skill` が command の頭に見えた★。
    ★本 repo は skill という語を日々使う★ (skills 機能) ⇒ ★放てば鳴り続ける禁になる★
    = ★家老の枷(6) が名指しで戒めた形そのもの★ゆえ、字と力を分ける所で落とす。

    ★`#` が語頭に在る時のみ註釈である★ = `foo#bar` や `$#` は註釈でない。
    """
    out: list[str] = []
    quote = "NONE"
    i, n = 0, len(command)
    at_word_start = True
    while i < n:
        c = command[i]
        if quote == "NONE":
            if c == "\\" and i + 1 < n:
                out.append(c)
                out.append(command[i + 1])
                i += 2
                at_word_start = False
                continue
            if c == "#" and at_word_start:
                while i < n and command[i] != "\n":   # 行末まで落とす
                    i += 1
                continue
            if c == "'":
                quote = "SQ"
            elif c == '"':
                quote = "DQ"
            at_word_start = c.isspace() or c in "|&;()<>"
        elif quote == "SQ":
            if c == "'":
                quote = "NONE"
        else:
            if c == "\\" and i + 1 < n and command[i + 1] in '"\\$`\n':
                out.append(c)
                out.append(command[i + 1])
                i += 2
                continue
            if c == '"':
                quote = "NONE"
        out.append(c)
        i += 1
    return "".join(out)


def unquoted_newlines_to_semicolons(command: str) -> str:
    r"""★引用の外に在る改行を `;` へ replace する★

    ★★何故 之が要るか — 己の門へ牙を立てて出た穴である (cmd_1411)★★
    借りた tokenize() は ★改行を operator ではなく【空白】として扱う★
    (`c.isspace()` の枝が `c in "|&;\n()"` の枝より先に在るゆえ)。
    ⇒ ★複数行の command が【一つの単純 command】に潰れる★ =

        cd /tmp
        pkill -f pytest          ← ★頭が `cd` と読まれ、pkill が引数に見えた★

    ★之を初走の 43/43 緑は一本も捕えておらなんだ★ =
    ★変異 M9 (heredoc 伏せを殺す) が生き残った所から手繰って出た★ =
    ★緑は【綺麗だから】ではなく【其の形を一本も置いておらなんだ】ゆえであった★。
    ★而して複数行こそ agent が日々書く形である★ ⇒ 塞がねば禁は有名無実になる。

    ★heredoc 本文を伏せた【後】に呼べ★ = 本文中の改行まで区切りに化けぬため。
    ★継続行 (`\` + 改行) は区切りでない★ゆえ、escape はそのまま通す。
    """
    out: list[str] = []
    quote = "NONE"
    i, n = 0, len(command)
    while i < n:
        c = command[i]
        if quote == "NONE":
            if c == "\\" and i + 1 < n:
                out.append(c)
                out.append(command[i + 1])   # 継続行を含め、escape は素通し
                i += 2
                continue
            if c == "'":
                quote = "SQ"
            elif c == '"':
                quote = "DQ"
            elif c == "\n":
                out.append(";")              # ★区切りへ化かす★
                i += 1
                continue
        elif quote == "SQ":
            if c == "'":
                quote = "NONE"
        else:  # DQ
            if c == "\\" and i + 1 < n and command[i + 1] in '"\\$`\n':
                out.append(c)
                out.append(command[i + 1])
                i += 2
                continue
            if c == '"':
                quote = "NONE"
        out.append(c)
        i += 1
    return "".join(out)


def _split_simple_commands(tokens) -> list[list]:
    """operator で区切って ★単純 command★ の列にする。

    ★旧禁も segment 分割はしておった★ (`true; kill -0 $$` が拒まれた実測が証拠) =
    ゆえに之を落とせば守りが後退する。同じ深さで割る。
    """
    out, cur = [], []
    for tok in tokens:
        if tok.is_operator:
            if cur:
                out.append(cur)
            cur = []
            continue
        cur.append(tok)
    if cur:
        out.append(cur)
    return out


def _resolve_head(words: list[str]) -> tuple[str | None, list[str]]:
    """先頭の代入と wrapper を剥がし、★真に走る command★ と其の引数を返す。"""
    i = 0
    n = len(words)
    while i < n:
        w = words[i]
        if _ASSIGNMENT_RE.match(w):          # FOO=bar cmd
            i += 1
            continue
        base = _basename(w)
        if base in WRAPPERS:
            i += 1
            # wrapper 自身の flag を読み飛ばす
            while i < n and words[i].startswith("-"):
                i += 1
            # timeout 5 kill … の "5" を食う
            if base in WRAPPER_EATS_ONE_ARG and i < n and not words[i].startswith("-"):
                i += 1
            continue
        return base, words[i + 1:]
    return None, []


def _signal_is_null(tool: str, args: list[str]) -> bool | None:
    """★送る signal が 0 (= 何も殺さぬ) と言い切れるか★

    True  = 0 と言い切れる    → 通す
    False = 0 でないと言い切れる → 拒む
    None  = ★言い切れぬ★      → 拒む側へ倒す (R4)
    """
    # --signal 0 / --signal=0 は全 tool 共通
    for idx, a in enumerate(args):
        if a == "--signal" and idx + 1 < len(args):
            return args[idx + 1] in ("0", "SIGNULL")
        if a.startswith("--signal="):
            return a.split("=", 1)[1] in ("0", "SIGNULL")

    if tool in ("kill", "skill"):
        for idx, a in enumerate(args):
            if a in ("-s", "-n") and idx + 1 < len(args):
                return args[idx + 1] in ("0", "SIGNULL")
            m = _NUMERIC_SIGNAL_RE.match(a)
            if m:
                return m.group(1) == "0"
            if _NAMED_SIGNAL_RE.match(a):
                return False        # -TERM / -KILL / -HUP …
        return False                # ★signal 無指定 = 既定 SIGTERM★

    if tool == "pkill":
        # ★★pkill の -s は session-id であって signal ではない★★
        #   ⇒ `pkill -s 0 …` を「signal 0」と読めば ★殺す物を通す★ = 最悪の誤り。
        #   ★之こそ綴りで判ずる禁が取り違える所★ゆえ、tool ごとに分けて解く。
        for a in args:
            m = _NUMERIC_SIGNAL_RE.match(a)
            if m:
                return m.group(1) == "0"
            if _NAMED_SIGNAL_RE.match(a) and a not in ("-s", "-n"):
                # -f/-e/-c 等の短 flag と signal 名を取り違えぬよう、
                # 既知の非 signal 短 flag は除く
                if a.lstrip("-").upper() in _SIGNAL_NAMES:
                    return False
        return False                # 無指定 = SIGTERM

    if tool == "killall":
        for idx, a in enumerate(args):
            if a == "-s" and idx + 1 < len(args):
                return args[idx + 1] in ("0", "SIGNULL")
            m = _NUMERIC_SIGNAL_RE.match(a)
            if m:
                return m.group(1) == "0"
            if _NAMED_SIGNAL_RE.match(a) and a.lstrip("-").upper() in _SIGNAL_NAMES:
                return False
        return False

    if tool == "fuser":
        # ★-k を伴わねば fuser は殺さぬ★ = 報告するだけ
        if not any(a in ("-k", "--kill") for a in args):
            return True
        return False

    if tool in ("xkill",):
        return False                # 無害な形を持たぬ

    if tool in ("taskkill", "taskkill.exe"):
        return False                # Windows。signal 0 に当たる物が無い

    return None


_SIGNAL_NAMES = {
    "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1",
    "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP",
    "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH",
    "POLL", "PWR", "SYS", "IO", "IOT", "CLD", "UNUSED",
}


def analyze(command: str) -> dict:
    """command を検め verdict を返す。戻り値 {"verdict","findings"}"""
    if not command or not command.strip():
        return {"verdict": "ALLOW", "findings": []}

    suspect = bool(_SUSPECT_RE.search(command))

    if not _TOKENIZER_OK:
        # R4: 気配が在るのに解く道具が無い → 拒む
        if suspect:
            return {
                "verdict": "DENY",
                "findings": [Finding(
                    tool="(解けず)", reason=(
                        "R4: tokenizer を借りられなんだゆえ command を解けぬ。"
                        f"signal 送出語の気配が在るゆえ ★拒む側へ倒した★ ({_TOKENIZER_ERR})"
                    ), excerpt=command[:80])],
            }
        return {"verdict": "ALLOW", "findings": []}

    try:
        scanned = mask_heredoc_bodies(command)
        # ★順を違えるな★ = ①heredoc 本文を伏せ ②註釈を落とし ③改行を区切りへ化かす。
        #   註釈落としは ★改行が在るうちに★ 行わねば「行末まで」が定まらぬ。
        #   改行化かしを先にすれば heredoc 本文の改行まで区切りになり、data が code に見える。
        scanned = strip_comments(scanned)
        scanned = unquoted_newlines_to_semicolons(scanned)
        tokens = tokenize(scanned)
    except Exception as exc:
        if suspect:
            return {
                "verdict": "DENY",
                "findings": [Finding(
                    tool="(解けず)",
                    reason=f"R4: command を解けなんだ。気配が在るゆえ拒む ({exc})",
                    excerpt=command[:80])],
            }
        return {"verdict": "ALLOW", "findings": []}

    findings: list[Finding] = []
    for simple in _split_simple_commands(tokens):
        words = [t.value for t in simple]
        if not words:
            continue
        head, args = _resolve_head(words)
        if head is None:
            continue

        # ★二語で殺す物 (tmux kill-pane / kill-window)★ — 無害な形を持たぬゆえ常に拒む
        if args and (head, args[0]) in TWO_WORD_KILLERS:
            findings.append(Finding(
                tool=f"{head} {args[0]}",
                reason=("R1: ★pane を殺せば其処に居る agent の process ごと死ぬ★ "
                        "(signal 0 に当たる無害な形が無い)"),
                excerpt=" ".join(words)[:80]))
            continue

        if head not in SIGNAL_SENDERS:
            continue

        # R3: signal を送らぬ副機能
        if any(a in INERT_FLAGS for a in args):
            continue

        null = _signal_is_null(head, args)
        if null is True:
            continue                     # R2: signal 0 = 通す
        if null is None:
            findings.append(Finding(
                tool=head,
                reason=("R4: 送る signal を読み切れなんだ ⇒ ★拒む側へ倒した★。"
                        "生存確認なら `-0` を明示せよ"),
                excerpt=" ".join(words)[:80]))
            continue
        findings.append(Finding(
            tool=head,
            reason=("R1/R2: ★走っておる process へ signal を送る形★である "
                    "(signal 0 ではない)"),
            excerpt=" ".join(words)[:80]))

    return {"verdict": "DENY" if findings else "ALLOW", "findings": findings}


def format_denial(result: dict) -> str:
    lines = [
        "★process を殺す力の関所 (cmd_1411) が止めた★",
        "",
    ]
    for f in result["findings"]:
        lines.append(f"  [{f['tool']}] {f['reason']}")
        lines.append(f"    該当: {f['excerpt']}")
    lines += [
        "",
        "★通る形 (力を持たぬ物は元より通る)★",
        "  ・生存確認    : kill -0 <pid> / pkill -0 -f <pat>   ← ★何も殺さぬゆえ通る★",
        "  ・探すだけ    : pgrep -af <pat>                      ← ★元より関所の外★",
        "  ・一覧/版表示 : kill -l / killall --help",
        "",
        "★真に殺す要が在るなら★ = ★判定を構造化して script へ落とせ★",
        "  形 = 「対象の cmdline が想定と違えば拒む・落とした後 再起動まで実測で見届ける」",
        "  ★先例だった scripts/legacy_guard_swap.sh (cmd_1339) は cmd_1479 第4束で撤去した★",
        "    = 呼び手が 1 本も無かったゆえ (殿が承認された掃除)。★今 開ける現物は無い★。",
        "    読みたい時 = git show f887dae:scripts/legacy_guard_swap.sh",
        "  ★迂回ではなく、殺してよい理由を機械が検める形にせよ★。",
    ]
    # ★★退化しておるなら【拒みの便へも】焼く (cmd_1411 (b))★★
    #   ★理由 = exit 0 の stderr は呼び手の目に入らぬ事が在る★が、
    #   ★exit 2 の stderr は必ず呼び手へ返る★ = ★拒まれた者は必ず出所を読める★。
    #   ⇒ ★「喧しい」と感じた其の便の中に、喧しさの出所が同梱されておる形★。
    _banner = degraded_banner()
    if _banner:
        lines += ["", _banner]
    return "\n".join(lines)


# ══════════════════════════════════════════════════════════════════════════
# selftest — ★塞いだ形が現に拒まれ、通す筈の物が現に通るかを両側で撃つ★ (殿の枷①)
# ══════════════════════════════════════════════════════════════════════════
_CASES: list[tuple[str, str, str]] = [
    # ── 拒むべき: 現に走る process へ signal を送る形 ──
    ("kill 12345",                       "DENY",  "素の kill = 既定 SIGTERM"),
    ("kill -9 12345",                    "DENY",  "SIGKILL"),
    ("kill -TERM 12345",                 "DENY",  "名前つき signal"),
    ("kill -s TERM 12345",               "DENY",  "-s 形"),
    ("/bin/kill -9 12345",               "DENY",  "★絶対 path — 旧禁が通しておった穴★"),
    ("/usr/bin/kill -TERM 1",            "DENY",  "★絶対 path (usr)★"),
    ("pkill -f pytest",                  "DENY",  "★pkill — 旧禁に一文字も無かった★"),
    ("pkill -9 -f gate_mutation_replay", "DENY",  "★六号が本朝 使うた形の族★"),
    ("pkill -s 0 -f foo",                "DENY",  "★pkill の -s は session であって signal でない★"),
    ("killall python3",                  "DENY",  "killall 素"),
    ("/usr/bin/killall -9 node",         "DENY",  "★絶対 path killall★"),
    ("skill -TERM -u me",                "DENY",  "★skill — 禁に現れぬ★"),
    ("xkill",                            "DENY",  "★xkill — 禁に現れぬ★"),
    ("fuser -k 9100/tcp",                "DENY",  "★fuser -k は殺す★"),
    ("taskkill.exe /F /PID 1234",        "DENY",  "★Windows 側 — 禁に現れぬ★"),
    ("env kill -9 1",                    "DENY",  "wrapper env を剥がす"),
    ("echo 1 | xargs kill -9",           "DENY",  "wrapper xargs を剥がす"),
    ("timeout 5 kill -9 1",              "DENY",  "timeout の数引数を食う"),
    ("true; kill -9 1",                  "DENY",  "★segment 分割 (旧禁も出来ておった)★"),
    ("cd /tmp && pkill -f foo",          "DENY",  "&& の後段"),
    ("FOO=bar kill -9 1",                "DENY",  "先頭の代入を剥がす"),
    ("nohup pkill -f x &",               "DENY",  "nohup を剥がす"),
    # ── ★改行で割る形 = 初走 43/43 緑が一本も見ておらなんだ穴★ (cmd_1411 自省) ──
    ("cd /tmp\npkill -f pytest",          "DENY",  "★改行区切り — agent が日々書く形★"),
    ("echo '畳む'\nkill -9 12345",        "DENY",  "★改行の後段★"),
    ("cd /x && echo a\n/bin/kill -TERM 9", "DENY", "★改行 + 絶対 path の重ね★"),
    ("set -e\ncd /tmp\nkillall node\ntrue", "DENY", "★三行目に沈めた形★"),

    # ── 通すべき: 力を持たぬ物 (★之を止めれば禁は外される★) ──
    ("kill -0 $$",                       "ALLOW", "★殿の A-5 の眼目 — 何も殺さぬ生存確認★"),
    ("kill -0 12345",                    "ALLOW", "生存確認 (pid 指定)"),
    ("kill -s 0 12345",                  "ALLOW", "-s 0"),
    ("kill -n 0 12345",                  "ALLOW", "-n 0"),
    ("while kill -0 40177 2>/dev/null; do sleep 20; done",
                                         "ALLOW", "★実在の待ち loop (transcript 実物)★"),
    ("kill -0 3917 2>/dev/null && echo ALIVE",
                                         "ALLOW", "★実在の生存確認 (transcript 実物)★"),
    ("pkill -0 -f 'zzz_no_such'",        "ALLOW", "pkill の signal 0"),
    ("kill -l",                          "ALLOW", "signal 一覧 — 送らぬ"),
    ("killall --help",                   "ALLOW", "★旧禁が止めておった — help は何も送らぬ★"),
    ("killall --version",                "ALLOW", "版表示"),
    ("skill -l",                         "ALLOW", "一覧"),
    ("fuser 9100/tcp",                   "ALLOW", "★-k 無し = 報告のみ★"),
    ("pgrep -af inbox_watcher",          "ALLOW", "★pgrep は問うだけ — 関所の外★"),
    ("ps -eo pid,args | grep kill",      "ALLOW", "★grep の綴り = 字であって力でない★"),
    ("grep -rn 'pkill' scripts/",        "ALLOW", "★同上 — 之を止めれば調査が出来ぬ★"),
    ("echo 'kill -9 1'",                 "ALLOW", "★引用の中は字★"),
    ("git commit -m 'fix: kill を禁ずる'", "ALLOW", "★commit message の中の字★"),
    # ★標本の file (legacy_guard_swap.sh) は cmd_1479 第4束で撤去済★ = ★入力の文字列はそのまま残す★。
    #   理由 = 此の標本が問うのは「bash <script> という形を通すか」であって、
    #   ★file が在るか無いかを見ていない★ (判定は綴りだけを読む)。書き替えれば標本の意味が変わる。
    ("bash scripts/legacy_guard_swap.sh --dry-run",
                                         "ALLOW", "★構造化された script は通す (射程外)★"),
    # ── ★裁(2) = tmux の pane 殺し (家老 10:26 の命で射程へ足した)★ ──
    ("tmux kill-pane -t multiagent:0.3", "DENY",  "★pane を殺せば agent ごと死ぬ★"),
    ("tmux kill-window -t x",            "DENY",  "★同上 (window)★"),
    ("cd /tmp\ntmux kill-pane -t x",     "DENY",  "★改行の後段でも★"),
    # ★通す側を先に数え上げてから塞ぐ (枷(6))★= agent が日々使う tmux は巻き込まぬ
    ("tmux display-message -t \"$TMUX_PANE\" -p '#{@agent_id}'",
                                         "ALLOW", "★自己識別 — 全 agent が毎回撃つ★"),
    ("tmux capture-pane -t multiagent:0.0 -p | tail -20",
                                         "ALLOW", "★家老の pane 確認★"),
    ("tmux list-panes -a -F '#{pane_id}'", "ALLOW", "一覧"),
    ("tmux send-keys -t x 'echo hi' Enter", "ALLOW", "★別の禁の所管 (本 guard の射程外)★"),
    ("tmux has-session -t multiagent",   "ALLOW", "存否を問うだけ"),
    ("ls -la",                           "ALLOW", "無関係"),
    ("cat <<'EOF'\nkill -9 1\nEOF",      "ALLOW", "★heredoc 本文 = data★"),
    ("bash scripts/x.sh <<'EOF'\npkill -f foo\nEOF",
                                         "ALLOW", "★heredoc 本文 (改行区切りの後も data のまま)★"),
    ("echo 'a\nkill -9 1'",              "ALLOW", "★引用の中の改行は区切りでない★"),
    ("grep -rn kill scripts/ \\\n  --include='*.sh'",
                                         "ALLOW", "★継続行 (\\ + 改行) は区切りでない★"),
    # ── ★註釈の中の字 = 実測 72,570 件で出た誤検知 2 件の形★ ──
    ("# backlog 更新(skill Step 4)\nls -la",
                                         "ALLOW", "★註釈中の skill — 実測の誤検知★"),
    ("# まず pkill -f foo で畳む\necho done",
                                         "ALLOW", "★註釈中の pkill★"),
    ("echo a  # kill -9 1",              "ALLOW", "★行末註釈★"),
    ("echo '# kill -9 1'",               "ALLOW", "引用の中の # は註釈でない"),
    ("kill -9 1 # 註釈",                  "DENY",  "★註釈の前は現に力である★"),
]


def selftest() -> int:
    ok = ng = 0
    print("=== process_signal_guard selftest (cmd_1411) ===")
    for cmd, expect, note in _CASES:
        got = analyze(cmd)["verdict"]
        if got == expect:
            ok += 1
            mark = "OK "
        else:
            ng += 1
            mark = "NG "
        print(f"  {mark} expect={expect:5s} got={got:5s} | {note}")
        if got != expect:
            print(f"       command: {cmd}")
    total = ok + ng
    d = sum(1 for _, e, _ in _CASES if e == "DENY")
    print(f"--- {ok}/{total} PASS  (DENY 期待 {d} 件 / ALLOW 期待 {total - d} 件)")
    if ng:
        print(f"NG {ng} 件 — ★此の guard は信用できぬ★")
        return 1
    print("PASS: ★塞ぐ側 と 通す側 の両方を撃った★")
    return 0


def main() -> int:
    # ★★退化しておるなら、判ずる前に一行 名乗る (cmd_1411 (b))★★
    #   ★健全なら一言も出さぬ★ = 常に鳴る門にせぬため。
    _banner = degraded_banner()
    if _banner:
        print(_banner, file=sys.stderr)

    if "--selftest" in sys.argv:
        return selftest()

    if "--command" in sys.argv:
        command = sys.argv[sys.argv.index("--command") + 1]
    else:
        try:
            payload = json.load(sys.stdin)
        except Exception as exc:
            # ★JSON が読めぬ = command が見えぬ = 気配も測れぬ★ ⇒ 通す (loud)
            print(f"[process_signal_guard] WARN: stdin JSON 解釈不能 — 通す: {exc}",
                  file=sys.stderr)
            return 0
        command = (payload.get("tool_input") or {}).get("command", "")

    if not command:
        return 0

    result = analyze(command)
    if result["verdict"] == "DENY":
        print(format_denial(result), file=sys.stderr)
        return 2   # PreToolUse: exit 2 = 実行を止め stderr を呼び手へ返す
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        # ★★此処は【無条件 fail-OPEN】である (cmd_1411 (b) で名乗りを実態へ合わせた)★★
        #   ★旧註は「気配が在れば拒み、無ければ通す (R4 の二段)」と申しておったが、
        #   ★実際は気配を一度も測らず通しておった★ (raw を組み立てて捨てる死に code が在った)
        #   = ★★門が己の射程を実際より広く名乗っておった形★★ = 本 repo が繰り返し狩ってきた族。
        #   ★R4 の二段は analyze() の中に現に在る★ (tokenizer 欠落・解析失敗の両方で気配を測る)
        #   ⇒ ★此処へ落ちるのは【analyze の外で起きた想定外】のみ★ =
        #     ★其の場で禁を掛ければ全 agent の Bash が止まりうる★ゆえ通す側へ倒す。
        #   ★但し黙って通さぬ★ = 一行 名乗る (下)。★守りを変えるなら家老の裁を経よ★。
        print(f"[process_signal_guard] WARN: 内部異常ゆえ ★検めずに通した★ "
              f"(fail-OPEN・R4 は掛かっておらぬ): {exc}", file=sys.stderr)
        sys.exit(0)
