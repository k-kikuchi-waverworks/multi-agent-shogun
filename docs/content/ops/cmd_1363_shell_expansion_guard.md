# cmd_1363 — 「道具へ渡す前に shell が食う」口を塞ぐ

> なぜこの関所が在るか。これが分からねば、次の者がこれを消す。

## 1. 何が起きたか (同日・別人・3件)

2026-07-26、**三人が別々に同じ穴を踏んだ**。個人の不注意ではなく **道具の形の問題** である。

| 誰 | 何が起きたか | 気付いた経緯 |
|----|-------------|-------------|
| 足軽五号 | 本文に書いた `` `docker rm -f vllm-8002` `` が **shell に実行され、報告からその部分が消えた** | 自分で読み返して気付き、自ら訂正 |
| 足軽四号 | 送った本文の **中身が5箇所 黙って欠けた**。`inbox_write.sh` は `[OK]` を返した | 送信後に karo.yaml を読み返して気付いた |
| 家老 | `ntfy.sh` で同型 (送信そのものが失敗)。さらに inbox 本文の backtick により **意図せず `docker rm` を実際に撃っておった** (幸い該当 container 無し) | 受信側の欠落から発覚 |

**共通点** = どれも赤くならなかった。道具は成功を報告し、届いた文だけが壊れておった。

## 2. なぜ道具の側では直せぬのか

```
agent が書いた command 文字列
        │
        │  ★ここで bash が展開する★ ← 原文が失われるのはこの一点
        ▼
    argv (もう手遅れ)
        │
        ▼
   inbox_write.sh   ← 受け取った時には既に変わっており、痕跡も残らぬ
```

`inbox_write.sh` をいくら固めても直らぬ。**原文がまだ在る唯一の場所 = shell が食う前**。
Claude Code の `PreToolUse` hook は **command 文字列を生で受け取る** ゆえ、ここに関所を置いた。

> これは cmd_1345 の続きである。あの時 python source の補間は全廃したが、それは
> **道具の内側** の口であった。本件は **道具へ届く手前** の口 = 同じ穴の別の口。

## 3. 口は4つある

五号が実測した3つに、本 cmd で1つ足した。

| 口 | 形 | 何が起きるか |
|----|----|-------------|
| (A) | `` "…`cmd`…" `` | 中身が実行され、その出力へ置換 |
| (B) | `"…$(cmd)…"` | 同じく置換 |
| (C) | `"…$VAR…"` (未定義) | **空文字へ置換 = エラーも出ず静かに消える (最も危うい)** |
| (D) | `<<EOF` (引用符なし) | **本文全体**が (A)(B)(C) に晒される |

**(A) だけを塞ぐな** — (B)(C)(D) が残れば同じ事が別の綴りで起きる (五号の警告)。

(D) は拙者が **自分の処方を疑うて** 足した。関所は逃げ道として heredoc を勧めるが、
裸の `<<EOF` は本文全体が展開に晒される = **勧めた逃げ道が、そのまま新しい口になりうる**。

実測 (塞ぐ前):

```
(C) intended: path=$IW_UNDEFINED_VAR_XYZ/models を見よ
    got     : path=/models を見よ          ← ★もっともらしい path になって届く★
```

## 4. 何を以て「危うい」と見なすか

**誤検知で信頼を失えば、その関所は無視されて死ぬ**。ゆえに線を明記する。

- **危うい** = 展開が **地の文に埋まっておる** (`"port は $SHA じゃ"`)。事故3件すべてこの形。
- **危うくない** = 引数が **まるごと1つの展開** (`"$msg"` / `"$(git log -1)"`)。
  呼び手の意図が明白ゆえ通す。既存 script の正当な呼び出しはすべてこの形。
- `\$` `` \` `` (escape 済) と `'…'` `<<'EOF'` は shell が食わぬゆえ安全。

**実測した誤検知率** = repo 内の実呼出・雛形 **261 件を走査して DENY 0 件**
(見かけ上の2件はいずれも markdown の backtick を剥がし損ねた走査側の傷で、真の呼出形は ALLOW)。

## 5. 安全な書き方

```bash
# ① 単引用符 (短文の最短形)
bash scripts/inbox_write.sh karo '本文に `…` や $VAR が在っても原文どおり' type from

# ② 引用符つき heredoc + --body-stdin (長文の本命)
bash scripts/inbox_write.sh karo --body-stdin type from <<'EOF'
本文をここへ。` も $(…) も $VAR も一切展開されぬ
EOF

# ③ file 渡し (Write tool で書けば shell を一切通らぬ)
bash scripts/inbox_write.sh karo --content-file /path/body.txt type from
```

`ntfy.sh` も同じ綴りを受ける。本当に展開させたい時は command 先頭へ `IW_ALLOW_EXPANSION=1`。

> **綴りの一致は機械が見張る** — 関所(python) と `inbox_write.sh`(bash) は別言語ゆえ
> 綴りが黙って食い違いうる (cmd_1350 の harness順/実機順と同型の罠)。食い違えば
> **「関所は逃げ道と認めたのに道具は受け取らぬ」= 逃げ場の無い関所** になる。
> `--selftest` の contract 突合が毎回これを検める (MUT-1363-004)。

## 6. 併せて塞いだ2つの沈黙

本 cmd の主題と **同じ family** ゆえ併せて塞いだ。

### (1) read-back verify が id しか見ておらなんだ

`inbox_write.sh` の「書けたつもり事故の最終網」(cmd_1338) は
`grep "id: $MSG_ID"` = **entry が在ることしか見ておらず、本文が変わって届いても緑**であった。
**中身の byte 突合へ格上げした**。

これは机上の心配ではない — **U+0085 (NEL) は YAML round-trip で空白へ黙って変わる** ことを実測した。
旧 verify はこれを緑で通す。新 verify は検知し、**配達を取り消して書込前へ戻す**
(不一致は決定的ゆえ retry せぬ = retry すれば同じ id の壊れた entry が3つ積まれる)。

> 由来は **四号の申し送り「送った後に自分の目で読み返すのが確か」** の機械化である。

### (2) ntfy.sh が送信失敗を黙って飲んでおった

旧版は HTTP status を log へ書くだけで **何が起きても exit 0**。
= **「撃ったこと」を成功の証拠にしており、「届いたこと」を見ておらなんだ**。
家老が送信失敗に気付けなんだのはこの沈黙が理由である。2xx 以外は大声で非0。

> 五号の教訓「解放は【撃った】でなく【VRAM が戻った】で確かめよ」の通知版。

## 7. 検め方 — exit code を信じてはならぬ

**本件の型は「送信は成功したまま (exit 0 / `[OK]`) 中身だけ変わる」**。
ゆえに全 test を **中身の突合** で判ずる (五号の具申)。

```bash
python3 scripts/shell_expansion_guard.py --selftest    # 関所 20件 + contract 突合
bats tests/test_cmd1363_shell_expansion.bats           # 19件 (G/D/V/N)
```

`--selftest` は **実事故の形を DENY**、**実在する既存呼出を ALLOW** の両側を撃つ。
片側だけでは「全部止める関所」も「何も止めぬ関所」も緑になる。

## 8. 台帳 (gate-2)

`MUT-1363-001`〜`006` を `config/mutation_registry.yaml` へ登録済。
**登録して終わりにせず、6件すべて runner で「壊せば名指しで落ちる」を実測した**。

`suspected_by` の内訳 = **ashigaru5=2 / ashigaru1=2 / ashigaru4=1 / karo=1**。
全軍規律「己で作った変異は、己が疑うた場所しか撃たぬ」に従い、
**他者の疑いを写した箇所は他者の名で刻んである** (口(A)(B)(C)は五号、
verify の中身突合は四号、ntfy の沈黙は家老が踏んだもの)。

> 登録時に踏んだ罠を記す — **`paths` の宣言漏れで baseline が赤くなり UNDETERMINED に落ちた**。
> 赤の理由が変異でなく「scratch に `lib/` `config/` が無い」であった。
> **UNDETERMINED は緑ではない** が、これを FAIL と読めば偽の牙折り報告になる。

## 9. 関わる file

| file | 役 |
|------|----|
| `scripts/shell_expansion_guard.py` | 関所本体 (PreToolUse hook)。`--selftest` / `--command` を持つ |
| `.claude/settings.json` | `PreToolUse` matcher=`Bash` で関所を呼ぶ **配線** |
| `scripts/inbox_write.sh` | 逃げ道 (`--body-stdin`/`--content-file`) + 中身突合 verify |
| `scripts/ntfy.sh` | 同じ逃げ道 + HTTP status の大声化 |
| `tests/test_cmd1363_shell_expansion.bats` | 19件 (G=関所 / D=原文どおり届く / V=変質検知 / N=ntfy) |
| `.gitignore` | 関所を **追跡下へ入れる否定規則** (無ければ fresh clone に渡らぬ) |

> **配線が要である** — 関所を書いても `.claude/settings.json` で呼ばねば
> 「目は開いたが呼ぶ者が居らぬ」番人になる (cmd_1359 が名指しした型)。
> 同様に `.gitignore` の否定規則が無ければ、hook 宣言だけが fresh clone へ渡り
> **呼ぶ相手の居らぬ番人** になる。
