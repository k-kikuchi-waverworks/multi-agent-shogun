#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""shell_expansion_guard.py — 「道具へ渡す前に shell が食う」経路の関所 (cmd_1363)

★なぜ受け手(inbox_write.sh)では直せぬのか★
    bash が展開を終えてから argv が渡る。inbox_write.sh が本文を受け取った時、
    backtick は既に「実行され、その出力へ置換された」後である。
    ★消えた文字は痕跡を残さぬ★ = 受け手側での検知は原理的に不可能。
    ⇒ 食われる前の生文字列を見られる層は2つしかない:
        (A) 呼び手の authoring 層  = Claude Code の PreToolUse hook が見る command 文字列 ← 本script
        (B) shell を通さぬ入力路   = --content-file / stdin           ← inbox_write.sh 側で新設

    これは cmd_1345 の続きである。あの時 python source 補間は塞いだが、
    ★argv がそこへ届く手前の shell 経路は開いたままであった = 同じ穴の別の口★。

★判定規則 (3本のみ・docs/shell_expansion_guard.md に同文)★
    R1: 本文位置の引数に backtick が「生」で在る (double-quote 内 or 無引用) → DENY。
        理由=本文中の backtick は markdown の意図であって shell の意図ではない。
        ★例外を設けぬ★ = 逃げ道 (single quote / --content-file) が一手で在るゆえ。
    R2: 本文位置の引数に展開 ($(...) / ${...} / $NAME) が在り、かつ
        ★展開部分を取り除いた残りが「散文」に見える★ (空白 or CJK を含む) → DENY。
        理由=`"$msg"` や `"$(git log -1)"` は意図した展開。
             `"port は $SHA じゃ"` は散文に紛れた事故。★残りが散文か否かで割れる★。
    R3: それ以外 → ALLOW。

★fail-OPEN (loud)★
    本 guard の誤りで全 agent の Bash が死ぬ方が害が大きい。ゆえに内部異常時は通す。
    ★但し黙って通さぬ★ = 異常は stderr と log へ出す (黙る番人こそ本 cmd の敵ゆえ)。
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import time

# 本文位置 = その道具の「人が書いた散文」が乗る引数番号 (1-origin)
GUARDED_TOOLS: dict[str, set[int]] = {
    "inbox_write.sh": {2},        # <target> <content> <type> <from>
    "ntfy.sh": {1, 2},            # <title> <body>  (どちらも散文)
}

# 展開の span を取るための正規表現 (優先順に食わせる)
_EXPANSION_RE = re.compile(
    r"""
      \$\( (?: [^()] | \([^()]*\) )* \)   # $( ... )  ネスト1段まで
    | \$\{ [^}]* \}                        # ${ ... }
    | \$ [A-Za-z_][A-Za-z0-9_]*            # $NAME
    | \$ [0-9@*#?$!-]                      # $1 $@ $? ...
    """,
    re.VERBOSE,
)

# 散文判定に使う CJK / 全角記号 (★【】、。 等を含む)
_PROSE_RE = re.compile(
    r"[\s\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uFF00-\uFFEF]"
)

_OPERATORS = {"|", "||", "&&", ";", "&", "\n", "(", ")", "{", "}", "|&"}

# 引用符なし heredoc (<<EOF / <<-EOF)。<<'EOF' <<"EOF" <<\EOF は展開されぬゆえ拾わぬ。
# (?<!<) で <<< (herestring) を除く。
_UNQUOTED_HEREDOC_RE = re.compile(r"(?<!<)<<-?[ \t]*(?P<delim>[A-Za-z_][A-Za-z0-9_]*)")

# ★heredoc の【始まり】を、引用符の有無ごと拾う (cmd_1388)★
#   <<EOF / <<-EOF / <<'EOF' / <<"EOF" / <<\EOF のいずれも delim を取り出す。
_HEREDOC_START_RE = re.compile(
    r"(?<!<)<<(?P<dash>-?)[ \t]*"
    r"(?:'(?P<sq>[^'\n]+)'"
    r"|\"(?P<dq>[^\"\n]+)\""
    r"|\\(?P<bs>[A-Za-z_][A-Za-z0-9_]*)"
    r"|(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"
)


def mask_heredoc_bodies(command: str) -> str:
    r"""★heredoc の本文を空白へ伏せた写しを返す (cmd_1388)★

    ★何を直すか★ = ★関所は【command の記述】と【command の実行】を見分けておらなんだ★。
    ★実例は同日に二度★:
      ・軍師一号 22:27 = ★本文中に書いた ntfy.sh の呼び出し【例】★を実際の呼び出しと読んで止めた
      ・家老     01:15 = ★本文中で【引用して説明した】裸のヒアドキュメント記法★を実物と読んで止めた
    ★実害は無かった (両者とも file 渡しへ回避した)★。★然れど危うさは別に在る★ =
    ★正当な安全経路が塞がれると、書き手が位置引数 (真に危うい口) へ逃げる誘因になる★。

    ★機序★ = analyze() は ★生の command 文字列★ を tokenize / 正規表現に掛けておった ⇒
    ★heredoc の本文 (= shell が一切手を触れぬ data) が、評価される位置と同列に読まれた★。

    ★処方★ = ★「実行される位置に在るか」で分けよ★ = 本文を伏せた写しの上で検める。
    ★本文を伏せてよい理由を、引用の有無ごとに分けて申す★:
      ・★<<'EOF' / <<"EOF" / <<\EOF★ = 本文は shell に触れられぬ ⇒ 検める意味が無い
      ・★<<EOF (引用符なし)★ = ★本文は現に展開へ晒される★。★但し其の危うさは
        【本文の中身】でなく【裸の口を開けた事】そのもの★ゆえ、R4 が operator の側で既に咎める
        ⇒ 本文を二度読む要は無い (咎めは消えておらぬ。負例 H3 が之を縛る)。

    ★射程を名乗る (この伏せ方が【見なくなる】もの)★:
      ★本 guard は inbox_write.sh / ntfy.sh の【散文引数】だけを見る関所であり、
        heredoc 本文が別の道具 (例: bash <<'EOF' … EOF) で実行される形は元より見ておらぬ★。
      ★本変更は其の射程を広げも狭めもせぬ★ = ★元から見ておらぬ物を、見ておらぬままにする★。
    """
    out: list[str] = []
    pending: list[tuple[str, bool]] = []   # [(delim, dash つきか)]
    for line in command.splitlines(keepends=True):
        if pending:
            delim, dash = pending[0]
            probe = line.rstrip("\n").rstrip("\r")
            if (probe.lstrip("\t") if dash else probe) == delim:
                pending.pop(0)          # 終端行は伏せぬ (構造を保つ)
                out.append(line)
                continue
            # ★本文 = 伏せる★。改行だけ残して桁を保ち、位置がずれぬようにする
            out.append(re.sub(r"[^\n\r]", " ", line))
            continue
        for m in _HEREDOC_START_RE.finditer(line):
            d = m.group("sq") or m.group("dq") or m.group("bs") or m.group("bare")
            pending.append((d, bool(m.group("dash"))))
        out.append(line)
    return "".join(out)

# ★shell を通らぬ本文受け口の綴り★ — inbox_write.sh 側の実装と【必ず一致させよ】。
#   食い違えば「guard は逃げ道と認めたのに道具は受け取らぬ」= 逃げ場の無い関所になる。
#   一致は selftest の contract 検査が機械で見張る (推測で足すな)。
BODY_SENTINELS = ("--content-file", "--body-file", "--stdin", "--body-stdin")

# ══════════════════════════════════════════════════════════════════════════
# 心拍 (cmd_1371) — ★関所が【此の pane で】生きておるかを、道具の側から測れる形★
# ══════════════════════════════════════════════════════════════════════════
# ★なぜ要るのか (実測から出た)★
#   cmd_1363 で関所も逃げ道も正しく据えた。にもかかわらず 2026-07-26 の一日で
#   ★関所が DENY と判ずる命令 21 件のうち 19 件がすり抜けた★ (本日分の全 session
#   記録を走査して実測・生データ = plans/cmd_1371_guard_leak_census.json)。
#   ★是正 2026-07-26 16:26: 初版は 38/2/36 と記した = 過大であった★ =
#     初版の走査は (a)file 単位ゆえ resume/compaction の写しを重複計上し (生38→unique28)
#     (b)絞りが file mtime のみゆえ 07-25 の record を本日分に混ぜた (unique28 中 7 件)。
#     ⇒ 検算つきの正しい数 = 21 = 止め 2 + すり抜け 19。★結論は不変 (19 は 2 の約10倍)★。
#     ★総数だけを出す集計は水増しを自ら申告せぬ = 内訳を同じ出力に並べよ★ (全軍規律)。
#   四号の原文を採り出して本 guard へ食わせると ★DENY★ = ★関所は正しく判じておった★。
#   ⇒ ★穴は「関所が無いこと」ではなく【関所が在るのに効いておるか誰も知らぬこと】★。
#
# ★Claude Code が hook 宣言をいつ取り込むかは、我らには観測できておらぬ★
#   (四号の session は関所据付の2時間34分【後】に開始しておるのに、すり抜けた)。
#   ⇒ ★機序を推測で埋めぬ。機序が判らずとも【判る】形にする★ のが本心拍である。
#
# ★この心拍が答える問い / 答えぬ問い (N3 の作法= 網の狭さを名乗る)★
#   答える  = 「関所は此の pane で走っておるか」
#   答えぬ  = 「此の本文が実際に検められたか」
#             (script の内側から inbox_write.sh を呼ぶ経路は、関所は元より見ておらぬ。
#              関所が見るのは agent が書いた command 文字列 1本だけである)
HEARTBEAT_DIRNAME = "queue/.shell_guard_heartbeat"
# 生きておると見なす猶予。PreToolUse は command の直前に走るゆえ通常1秒未満。
# ★短く採る★ = 長く採れば「守られておらぬ」を「守られておる」と読む側へ倒れる =
#   本日ずっと退けてきた偽の緑そのものになる。
HEARTBEAT_FRESH_SEC = 90


def heartbeat_key(payload: dict | None = None) -> str:
    """心拍の鍵。★pane 単位★ = agent 単位で分ける。

    全 agent が同じ repo で走るゆえ、鍵を1つにすると
    ★関所が死んでおる pane が、隣の pane の心拍を見て「生きておる」と読む★。
    それは今日 四号に起きたことを、そのまま見逃す形になる。
    """
    raw = os.environ.get("TMUX_PANE") or (payload or {}).get("session_id") or "nopane"
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(raw))[:64]


def heartbeat_dir() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent / HEARTBEAT_DIRNAME


def touch_heartbeat(payload: dict | None = None) -> None:
    """★関所が走った証★ を残す。ALLOW/DENY を問わず必ず残す。

    ★fail-OPEN (loud)★ = 心拍が書けぬことで agent の Bash を止めてはならぬ。
    """
    try:
        d = heartbeat_dir()
        d.mkdir(parents=True, exist_ok=True)
        (d / heartbeat_key(payload)).write_text(
            f"{time.time():.3f} {os.getpid()}\n", encoding="utf-8"
        )
    except Exception as exc:
        print(f"[shell_expansion_guard] WARN: 心拍を残せなんだ — 続行: {exc}",
              file=sys.stderr)


class Segment:
    """token を構成する断片と、その断片の引用状態。

    quote: "NONE" | "SQ" | "DQ"
      SQ (single quote) 内は shell が一切展開せぬ = 安全。
    """

    __slots__ = ("text", "quote")

    def __init__(self, text: str, quote: str) -> None:
        self.text = text
        self.quote = quote


class Token:
    __slots__ = ("segments", "is_operator")

    def __init__(self, segments: list[Segment], is_operator: bool = False) -> None:
        self.segments = segments
        self.is_operator = is_operator

    @property
    def value(self) -> str:
        """引用符を剥がした後の見かけの文字列 (展開はせぬ)。"""
        return "".join(s.text for s in self.segments)

    @property
    def unsafe_text(self) -> str:
        """★shell が展開しうる部分だけ★ を連結したもの (SQ を除く)。"""
        return "".join(s.text for s in self.segments if s.quote != "SQ")


def tokenize(command: str) -> list[Token]:
    """引用状態を保ったまま command を token へ割る。

    ★展開は一切せぬ★ — 「食われる前」を見るのが本 guard の全てゆえ。
    heredoc/複雑な case は完全には解けぬ。解けぬ時は素直に諦めて ALLOW 側へ倒す
    (fail-OPEN の方針と揃える)。
    """
    tokens: list[Token] = []
    segs: list[Segment] = []
    buf: list[str] = []
    quote = "NONE"
    i = 0
    n = len(command)

    def flush_seg() -> None:
        if buf:
            segs.append(Segment("".join(buf), quote))
            buf.clear()

    def flush_token() -> None:
        flush_seg()
        if segs:
            tokens.append(Token(list(segs)))
            segs.clear()

    while i < n:
        c = command[i]

        if quote == "NONE":
            if c == "\\":
                # 無引用の backslash escape: 次の1文字はそのまま (展開されぬ)
                if i + 1 < n:
                    flush_seg()
                    segs.append(Segment(command[i + 1], "SQ"))  # escape 済 = 安全扱い
                    i += 2
                    continue
                i += 1
                continue
            if c == "'":
                flush_seg()
                quote = "SQ"
                i += 1
                continue
            if c == '"':
                flush_seg()
                quote = "DQ"
                i += 1
                continue
            if c.isspace():
                flush_token()
                i += 1
                continue
            if c in "|&;\n()":
                flush_token()
                # 2文字 operator (&& ||) をまとめる
                op = c
                if i + 1 < n and command[i + 1] == c and c in "|&":
                    op = c * 2
                    i += 1
                tokens.append(Token([Segment(op, "NONE")], is_operator=True))
                i += 1
                continue
            buf.append(c)
            i += 1
            continue

        if quote == "SQ":
            if c == "'":
                flush_seg()
                quote = "NONE"
                i += 1
                continue
            buf.append(c)
            i += 1
            continue

        # quote == "DQ"
        if c == "\\" and i + 1 < n and command[i + 1] in '"\\$`\n':
            # DQ 内で escape が効くのはこの5文字のみ = 展開されぬゆえ安全扱い
            flush_seg()
            segs.append(Segment(command[i + 1], "SQ"))
            i += 2
            continue
        if c == '"':
            flush_seg()
            quote = "NONE"
            i += 1
            continue
        buf.append(c)
        i += 1

    flush_token()
    return tokens


def _strip_expansions(text: str) -> str:
    return _EXPANSION_RE.sub("", text)


def inspect_argument(raw_unsafe: str) -> list[str]:
    """本文位置の引数1つを検め、違反理由の list を返す (空 = 健全)。"""
    reasons: list[str] = []

    # R1: 生 backtick
    if "`" in raw_unsafe:
        reasons.append(
            "R1: 本文に backtick が生で在る — shell が【道具へ渡す前に】中身を "
            "command として実行し、その位置を出力で置換する。"
            "★本文は黙って欠け、意図せぬ command が走る★"
        )

    # R2: 展開 + 残りが散文
    expansions = _EXPANSION_RE.findall(raw_unsafe)
    if expansions:
        remainder = _strip_expansions(raw_unsafe)
        if _PROSE_RE.search(remainder):
            sample = expansions[0] if isinstance(expansions[0], str) else str(expansions[0])
            reasons.append(
                f"R2: 散文の中に shell 展開 ({sample}) が在る — "
                "未定義なら【黙って空文字】へ、定義済なら別の値へ置換される。"
                "★port 番号や hash であれば、1文字消えた報告と気付けぬ★"
            )
    return reasons


def analyze(command: str) -> dict:
    """command 文字列を検め、verdict と理由を返す。

    戻り値: {"verdict": "ALLOW"|"DENY", "findings": [ {...} ]}
    """
    findings: list[dict] = []
    # ★検めるのは【shell が評価する位置】だけである (cmd_1388)★ =
    #   heredoc 本文は data ゆえ伏せた写しの上で読む。★伏せる理由と射程は
    #   mask_heredoc_bodies() の docstring に実例つきで記した★。
    scanned = mask_heredoc_bodies(command)
    tokens = tokenize(scanned)

    # R4: ★引用符なし heredoc★ (cmd_1363 後段で足した口)
    #   本 guard は逃げ道として --content-file / --stdin を勧める。だが stdin へ本文を
    #   流す最短の形は heredoc であり、★<<EOF (引用符なし) は本文全体が展開に晒される★。
    #   = ★勧めた逃げ道が、そのまま新しい口になりうる★ ゆえここで塞ぐ。
    #   <<'EOF' / <<"EOF" / <<\EOF は展開されぬゆえ通す。<<< (herestring) は別物ゆえ拾わぬ。
    if any(
        tok.value.rsplit("/", 1)[-1] in GUARDED_TOOLS
        for tok in tokens
        if not tok.is_operator
    ):
        for m in _UNQUOTED_HEREDOC_RE.finditer(scanned):
            delim = m.group("delim")
            findings.append(
                {
                    "tool": "heredoc",
                    "arg_index": 0,
                    "reason": (
                        f"R4: 引用符なし heredoc (<<{delim}) — ★本文全体★ が展開に晒され、"
                        f"`…` も $(…) も $VAR も食われる。<<'{delim}' と単引用符で囲めば"
                        "shell は一切手を触れぬ"
                    ),
                    "excerpt": m.group(0),
                }
            )

    for idx, tok in enumerate(tokens):
        if tok.is_operator:
            continue
        basename = tok.value.rsplit("/", 1)[-1]
        positions = GUARDED_TOOLS.get(basename)
        if not positions:
            continue

        # 後続の引数を拾う (operator に当たったら command 境界ゆえ打ち切り)
        args: list[Token] = []
        for nxt in tokens[idx + 1:]:
            if nxt.is_operator:
                break
            args.append(nxt)

        # ★逃げ道が使われておれば検めぬ★ = shell を通っておらぬゆえ
        arg_values = [a.value for a in args]
        # --body-file=PATH (= つき) も同じ逃げ道ゆえ prefix で見る
        if any(
            v == s or v.startswith(s + "=") for v in arg_values for s in BODY_SENTINELS
        ):
            continue

        for pos in sorted(positions):
            if pos > len(args):
                continue
            arg = args[pos - 1]
            for reason in inspect_argument(arg.unsafe_text):
                findings.append(
                    {
                        "tool": basename,
                        "arg_index": pos,
                        "reason": reason,
                        "excerpt": arg.value[:80],
                    }
                )

    return {"verdict": "DENY" if findings else "ALLOW", "findings": findings}


def format_denial(result: dict) -> str:
    lines = [
        "★shell 展開の関所 (cmd_1363) が止めた — このまま撃てば本文が黙って欠ける★",
        "",
    ]
    for f in result["findings"]:
        lines.append(f"  [{f['tool']} 第{f['arg_index']}引数] {f['reason']}")
        lines.append(f"    該当: {f['excerpt']}")
    lines += [
        "",
        "★直し方 (どれか一手)★",
        "  1. 本文を single quote で囲む  → shell は一切展開せぬ",
        "  2. backtick の代わりに 【 】 を使う (家老が 2026-07-26 に採った作法)",
        "  3. ★引用符つき heredoc + --body-stdin (長文の本命)★",
        "       bash scripts/inbox_write.sh <target> --body-stdin <type> <from> <<'EOF'",
        "       本文をここへ。` も $(…) も $VAR も一切展開されぬ",
        "       EOF",
        "     ★<<'EOF' と単引用符で囲め — 裸の <<EOF は本文全体が展開に晒される★",
        "  4. 長文・引用符が入り組む本文は --content-file を使う:",
        "       (Write tool で本文を file へ書く)",
        "       bash scripts/inbox_write.sh <target> --content-file <path> <type> <from>",
        "     ★shell を一切通らぬゆえ、この経路には本穴が存在せぬ★",
    ]
    return "\n".join(lines)


# ──────────────────────────────────────────────────────────────
# selftest — ★誤検知を測る★ (家老 cmd_1352 裁定: 常に赤い検知は無視されて死ぬ)
# ──────────────────────────────────────────────────────────────

# (command, 期待 verdict, 説明)
_CASES: list[tuple[str, str, str]] = [
    # ── DENY されるべき: 実際に起きた事故そのもの ──
    (
        'bash scripts/inbox_write.sh karo "五号は `docker rm -f vllm-8002` を撃った" task_assigned karo',
        "DENY",
        "★家老が 2026-07-26 に実際に踏んだ形★ — backtick が実行され本文が欠けた",
    ),
    (
        'bash scripts/inbox_write.sh ashigaru1 "hash は $COMMIT_SHA じゃ" task_assigned karo',
        "DENY",
        "散文に紛れた $VAR — 未定義なら黙って空へ",
    ),
    (
        'bash scripts/inbox_write.sh karo "port は $(echo 9100) である" report ashigaru1',
        "DENY",
        "散文に紛れた $(...)",
    ),
    (
        'bash scripts/ntfy.sh "✅ cmd_1363 完了" "本文に `code` が在る"',
        "DENY",
        "ntfy.sh 本文の backtick — 家老が同日踏んだ同型",
    ),
    (
        'bash scripts/ntfy.sh "🚨 $CMD_ID 滞留" "state"',
        "DENY",
        "ntfy.sh 第1引数(title)の散文 + $VAR",
    ),
    (
        'cd /mnt/c/tools/multi-agent-shogun && bash scripts/inbox_write.sh karo "残 `wc -l < f` 行" report ashigaru1',
        "DENY",
        "&& を跨いでも本文位置を見失わぬ",
    ),
    # ── ALLOW されるべき: ★既存の実呼出 (誤検知を測る本体)★ ──
    (
        'bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly',
        "ALLOW",
        "scripts/gate_nightly.sh:72 の実物 — 展開のみで散文なし",
    ),
    (
        'bash "$ROOT_DIR/scripts/inbox_write.sh" "$a" "$msg" task_assigned night_blackout_guard',
        "ALLOW",
        "scripts/night_blackout_guard.sh:181 の実物",
    ),
    (
        'bash scripts/inbox_write.sh karo "$(git log -1 --oneline)" report ashigaru1',
        "ALLOW",
        "意図した $(...) 単体 — 展開を除くと残りが空",
    ),
    (
        'bash scripts/inbox_write.sh karo "cmd_$ID" report ashigaru1',
        "ALLOW",
        "接頭辞つき変数 — 残りに空白も CJK も無い",
    ),
    (
        "bash scripts/inbox_write.sh karo '五号は `docker rm -f x` を撃った' task_assigned karo",
        "ALLOW",
        "★single quote = shell が展開せぬ = 本来の正しい書き方★",
    ),
    (
        'bash scripts/inbox_write.sh karo "軍師の検分は PASS であった" report ashigaru1',
        "ALLOW",
        "普通の日本語本文 — 展開も backtick も無い",
    ),
    (
        'bash scripts/inbox_write.sh karo "本文に \\` を escape して書く" report ashigaru1',
        "ALLOW",
        "backslash escape 済 backtick は展開されぬ",
    ),
    (
        'bash scripts/inbox_write.sh karo --content-file /tmp/body.txt task_assigned karo',
        "ALLOW",
        "★逃げ道 (--content-file) は shell を通らぬゆえ検めぬ★",
    ),
    (
        'git commit -m "fix: `backtick` in commit message"',
        "ALLOW",
        "★関所の外 (guard 対象の道具でない) — 越権に検めぬ★",
    ),
    (
        'echo "port は $PORT" > /tmp/x',
        "ALLOW",
        "★inbox_write.sh/ntfy.sh 以外は対象外★ — 誤検知を広げぬ",
    ),
    # ── R4: 引用符なし heredoc (勧めた逃げ道が新しい口にならぬように) ──
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<EOF\n"
        "五号は `docker rm -f x` を撃った\nEOF",
        "DENY",
        "★<<EOF (引用符なし) = 本文全体が展開に晒される★ — 逃げ道の顔をした口",
    ),
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<'EOF'\n"
        "五号は `docker rm -f x` を撃った\nEOF",
        "ALLOW",
        "★<<'EOF' = shell が一切手を触れぬ = 長文の本命★",
    ),
    (
        'bash scripts/inbox_write.sh karo --body-file=/tmp/body.txt task_assigned karo',
        "ALLOW",
        "= つきの逃げ道も prefix で認める",
    ),
    (
        'cat f | bash scripts/ntfy.sh "🚨 滞留" "$(cat /tmp/x)" <<<"herestring"',
        "ALLOW",
        "<<< (herestring) は heredoc でない — 誤って拾わぬ",
    ),
    # ── ★cmd_1388: 【command の記述】と【command の実行】を見分ける★ ──────
    #   ★同日に二度 実際に踏まれた形である (偶発でなく形である裏づけ)★:
    #     軍師一号 22:27 / 家老 01:15 — いずれも実害無し (file 渡しへ回避) だが、
    #     ★正当な安全経路が塞がれると書き手が位置引数 (真に危うい口) へ逃げる★。
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<'EOF'\n"
        "★裸のヒアドキュメント (<<EOF) を使うな★と説明しておるだけの本文である\nEOF",
        "ALLOW",
        "★H1: 家老 01:15 の実物型 — 本文で【引用して説明した】記法を実物と読まぬ★",
    ),
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<'EOF'\n"
        'たとえば bash scripts/ntfy.sh "題" "本文に `code` が在る" と書けば止まる\nEOF',
        "ALLOW",
        "★H2: 軍師一号 22:27 の実物型 — 本文中の呼び出し【例】を実際の呼び出しと読まぬ★",
    ),
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<EOF\n"
        "本文で <<'EOF' の書き方を説明しておる\nEOF",
        "DENY",
        "★H3: 危うい側は今も止まる — 本文を伏せても【裸の口を開けた事】は咎める★",
    ),
    (
        'bash scripts/inbox_write.sh karo "残 `wc -l < f` 行" report ashigaru6',
        "DENY",
        "★H4: 本文を伏せても【実引数】の目は塞がらぬ (伏せ方が広すぎぬことの証)★",
    ),
    (
        'bash scripts/inbox_write.sh karo "残 `wc -l < f` 行" report ashigaru6 --body-stdin',
        "ALLOW",
        "★H4b: ★★既知の穴★★ — 逃げ道が1つでも在れば其の呼出を一切検めぬ造りゆえ、"
        "同じ行の位置引数の backtick を見逃す。★shell は現に其れを食う★。"
        "★HEAD 版でも同じ = cmd_1388 の変更が作った物ではない (実測で確かめた)★。"
        "★免除でなく【穴として名指した札】である★ = 家老へ具申済・別 cmd の種",
    ),
    (
        "bash scripts/inbox_write.sh karo --body-stdin task_assigned karo <<'A'\n"
        "説明の本文\nA\nbash scripts/inbox_write.sh gunshi1 --body-stdin report karo <<B\n"
        "二本目は裸である\nB",
        "DENY",
        "★H5: 一本目が引用つきでも、二本目の裸の口を見失わぬ★",
    ),
]


def contract_check() -> int:
    """★関所が認めた逃げ道を、道具が本当に受け取るか★ を機械で突合する。

    guard と inbox_write.sh は別言語ゆえ綴りが黙って食い違いうる (cmd_1350 の
    harness順/実機順と同型の罠)。食い違えば「関所は逃げ道と認めたのに道具は
    受け取らぬ」= ★逃げ場の無い関所★ になる。ゆえに散文の約束でなく機械で見張る。
    """
    import pathlib

    iw = pathlib.Path(__file__).resolve().parent / "inbox_write.sh"
    print("=== contract: guard の逃げ道 ⇔ inbox_write.sh の実装 ===")
    if not iw.is_file():
        print(f"  UNDETERMINED: {iw} が無い — 突合できぬ")
        return 2
    src = iw.read_text(encoding="utf-8", errors="replace")
    ng = 0
    for s in BODY_SENTINELS:
        # case 分岐の枝として実在するか (docstring の言及では通さぬ)
        if re.search(rf"^\s*(?:[-\w=*|]*\|)?{re.escape(s)}[|)=]", src, re.M):
            print(f"  OK  {s} — inbox_write.sh が受け取る")
        else:
            print(f"  NG  ★{s} を guard は逃げ道と認めておるが inbox_write.sh に実装が無い★")
            ng += 1
    if ng:
        print(f"NG {ng} 件 — 逃げ場の無い関所になっておる")
        return 1
    print(f"PASS: 逃げ道 {len(BODY_SENTINELS)} 綴りすべてが道具側に実在する")
    return 0


def selftest() -> int:
    ok = 0
    ng = 0
    print("=== shell_expansion_guard selftest (cmd_1363) ===")
    for cmd, expect, note in _CASES:
        got = analyze(cmd)["verdict"]
        mark = "OK " if got == expect else "NG "
        if got == expect:
            ok += 1
        else:
            ng += 1
        print(f"  {mark} expect={expect:5s} got={got:5s} | {note}")
        if got != expect:
            print(f"       command: {cmd}")
    total = ok + ng
    deny_cases = sum(1 for _, e, _ in _CASES if e == "DENY")
    allow_cases = total - deny_cases
    print(f"--- {ok}/{total} PASS (DENY 期待 {deny_cases}件 / ALLOW 期待 {allow_cases}件)")
    if ng:
        print(f"NG {ng} 件 — guard は信用できぬ")
        return 1
    print("PASS: 実事故4形を捕らえ、実在する既存呼出すべてを素通しした (誤検知 0)")
    return contract_check()


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    payload: dict | None = None
    if "--command" in sys.argv:
        command = sys.argv[sys.argv.index("--command") + 1]
    else:
        # hook 経路: PreToolUse の JSON が stdin へ来る
        try:
            payload = json.load(sys.stdin)
        except Exception as exc:  # fail-OPEN (loud)
            print(f"[shell_expansion_guard] WARN: stdin JSON 解釈不能 — 通す: {exc}",
                  file=sys.stderr)
            # ★心拍は残す★ = JSON が読めずとも「関所は呼ばれた」は真ゆえ。
            touch_heartbeat(None)
            return 0
        command = (payload.get("tool_input") or {}).get("command", "")
        # ★心拍は hook 経路でのみ残す★ = --command は人が手で撃つ検分用であり、
        #   それを心拍に数えれば ★検分した者の pane だけが偽って「守られておる」★ になる。
        touch_heartbeat(payload)

    if not command:
        return 0

    result = analyze(command)
    if result["verdict"] == "DENY":
        print(format_denial(result), file=sys.stderr)
        return 2  # PreToolUse: exit 2 = tool 実行を止め、stderr を呼び手へ返す
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # ★fail-OPEN だが黙らぬ★
        print(f"[shell_expansion_guard] WARN: 内部異常 — 通す (fail-OPEN): {exc}",
              file=sys.stderr)
        sys.exit(0)
