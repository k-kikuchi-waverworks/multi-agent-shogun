# report YAML の自己検め (cmd_1395)

`scripts/report_validate.py` — report YAML が壊れた其の場で、**書き手へ**名指す門。

## 1. なぜ要るか — 稀な事故ではなく常態である

report は家老の唯一の受領経路である。**壊れれば、完遂が黙って消える**。

本夜 現に起きた = 軍師一号の report が parse 落ち (line 1881・list の途中へ mapping を挿し
込み最後の list 要素が孤児になった) → 番人が其の完遂を読めず「働いておるのに idle」と誤判定
(五号が `idle_revive_scan.py --dry-run` で別経路から裏付け)。

**そして之は一度きりではなかった。** `logs/idle_revive_scan.log` を数えた:

```
report YAML parse failed の行数 = 138
  gunshi1_report.yaml   28    ashigaru5_report.yaml 13
  gunshi2_report.yaml   27    ashigaru2_report.yaml 13
  ashigaru3_report.yaml 20    ashigaru1_report.yaml  7
  ashigaru4_report.yaml 17
  ashigaru6_report.yaml 13
```

**書き手 8 名すべてに前科が在る。**
（刻の但し書き = 138 行のうち時刻を当てられるのは 8 行のみ。`===== scan <ISO>` の marker が
log へ入ったのが 2026-07-26T21:06 ゆえ、それ以前の 130 行は此の log だけでは日付を言えぬ。
**言えぬ物を言えると書かぬ**。）

## 2. 壊れた report が招く害 — 二つ、いずれも実測

### 害A: 番人から姿が消える（本夜の実害）
`idle_revive_scan.py:1302` / `stall_watchdog_scan.py:112` は `safe_load_all` で読む。
落ちれば WARN を吐いて `False` を返す = **「完遂しておらぬ」と同じ扱い**。
⇒ 働いておる者が idle と誤判定され、`/clear` を撃たれうる。

### 害B: report が queue/reports/ から攫われる（cmd_1395 で新たに掴んだ）
家老は毎 cycle の step 1.5 で `bash scripts/slim_yaml.sh karo` を撃つ (`instructions/karo.md:39`)。
`slim_reports()` は `load_yaml` (=`safe_load`) で読み、**落ちると `{}` を返す** (`slim_yaml.py:273`)。
⇒ `parent_cmd` が読めぬ ⇒ 非 active と見なされ、24h stale になった時 `queue/archive/reports/` へ移される。

sandbox で実走して確かめた（親 cmd も staleness も同一・**違いは parse できるか だけ**）:

```
reports/ に残った物 : ['gunshi1_report.yaml']    ← 健全
archive/ へ移った物 : ['gunshi2_report.yaml']    ← 孤児 list を仕込んだ方
```

★但し射程を限る★ = `CANONICAL_REPORTS` (= `ashigaru1〜8_report` と `gunshi_report`) は
slim_reports が読む前に skip する。**射程に入るのは `gunshi1_report` / `gunshi2_report`** =
奇しくも失敗件数 1 位と 2 位 (28 / 27) の二つである。

## 3. 判定規則 — 発明せず、実在の読み手から写す

此の門が問うのは「YAML として綺麗か」ではない。**現に居る読み手が読めるか**である。

| 規則 | 何を見るか | 守っておる読み手 | 破れた時の害 |
|------|-----------|-----------------|-------------|
| R1 | `safe_load_all` | `idle_revive_scan.py:1302` / `stall_watchdog_scan.py:112` | 害A = 完遂が届かぬ |
| R2 | `safe_load` (単一 doc)。**除外表に無い stem のみ** | `slim_yaml.py:273` | 害B = archive へ攫われる |
| R3 | mapping 内の同名 key | 全員（load 時には既に先の値が無い） | 記録が後勝ちで黙って消える |
| R4 | document が mapping か | 全員（`isinstance(doc, dict)` で黙って skip） | 落ちもせず読まれもせぬ |

- R2 の除外表は `slim_yaml` から **import する**（写経すれば読み手と門が黙って割れるゆえ）。
  ゆえに `ashigaru3_report.yaml` は今 2 document だが **緑**である = 其れを読む者が居らぬゆえ。
  同じ本文でも `gunshi1_report` の名なら **赤**になる。**規則は file の名で変わる。読み手が変わるゆえ。**
- R3 は `ledger_validate.py` の cmd_1341 と同型（台帳で起きた事は report でも起きる）。

## 4. 何処へ据えたか — (a)(b)(c) を実測で比べ、(b) 単一を採る

| | (a) agent が自ら1行 | **(b) PostToolUse hook ←採用** | (c) 常駐 watcher |
|--|--|--|--|
| 費用 | 0.09s/回 | **素通り 0.03s / 検め 0.09s**（実測・最大 258KB の report） | 常駐 process + inotify |
| 覆う範囲 | 憶えておる限り | **12/12 agent 枠**（全て `type: claude` を実測） | 全 file（但し書き手には届かぬ） |
| 書き手へ届くか | 届く | **届く（同じ tool 呼出の中で返る）** | **届かぬ**（log か第三者へ） |
| 実績 | **138 件が之で漏れた** | — | **138 件を現に見て、何も変わらなんだ** |

**(c) を退けた決め手は思弁ではない。** 番人は既に watcher として 138 回 WARN を吐いておる。
**見ておったのに、何も起きなんだ。** 「守りが増えたつもり」の実物が此処に在る。

**(a) を退けた決め手も同じ形。** 「valid な YAML を書け」という規律は既に在り、其の下で
書き手 8 名 全員が破った。加えて足軽は `/clear` 復帰時に `instructions/*.md` を読まぬ規約ゆえ、
規律を其処へ書けば復帰直後は必ず空振りする。

## 5. ★采用した (b) の限界 — 二つ、いずれも実測で掴んだ★

1. **既に走っておる session では鳴らぬ。** `.claude/settings.json` へ配線した直後に probe を
   書いたが feedback は来なんだ。同時刻に `queue/.shell_guard_heartbeat/` は更新されており、
   **hook 機構そのものは生きておった** ⇒ 死んでおるのは「新しい配線が session 開始時の
   snapshot に載っておらぬ」一点。**各 agent が session を開き直す (`/clear` 等) まで効かぬ。**
2. **claude 以外の CLI では鳴らぬ。** `config/settings.yaml` は codex/copilot/kimi も採れる。
   今は 12/12 が claude ゆえ穴は無いが、**切り替えた其の日に黙って消える守りである**。

⇒ 之を見えるようにするため、門は **心拍**を残す (`queue/.report_guard_heartbeat/<pane>`)。
`python3 scripts/report_validate.py --liveness` で「此の pane で門が走っておるか」を測れる。
**心拍が無ければ「苦情が出ぬ」を【report が綺麗】とも【門が一度も走っておらぬ】とも読める。**

## 6. 使い方

```bash
python3 scripts/report_validate.py queue/reports/ashigaru1_report.yaml   # 手検め (0=PASS/1=FAIL)
python3 scripts/report_validate.py --selftest                            # 変異試験 (赤/緑)
python3 scripts/report_validate.py --liveness                            # 門が生きておる pane
```

`--selftest` は M1〜M4 の変異で赤・無改変で緑・**且つ現に在る report 全数が緑**であることまで見る
（門が狼少年でない証を、盤面の側でも取る）。

## 7. ★道中で掴んだ別口 — 再帰 grep が新造 file を黙って落とす★

本 cmd の anchor 一意性を数えようとして踏んだ。**報告の値打ちは門より此方が高いやも知れぬ。**

- 此の shell の `grep` は **bash function** であり、中身は `ugrep -G --ignore-files ...` である
  (`type grep` で実測)。`--ignore-files` は **`.gitignore` を尊ぶ**。
- 本 repo の `.gitignore` は **白名簿** (`*` で全除外 → `!` で個別許可)。
- ⇒ **白名簿に載るまで、新造 file は `grep -rn ... .` の再帰から消える。**
  実測 = 同じ pattern が `./scripts` 指定では 14 件、`.` 指定では 13 件。落ちておったのは
  **今まさに登録しようとしておる当の新造 file** であった。

**害** = 規律(8)「anchor の当たり先が 1 件か数えよ」も、cmd_1380 型の「全数当たり」も、
再帰 grep で数えれば **未追跡の file を数え落とす**。しかも 0 件は「安心」の顔で返る。

**作法** = 数える時は explicit path か `git ls-files` を使い、**未追跡は別勘定で数えよ**
（`git ls-files` もまた未追跡を含まぬ = 二つは違う抜け方をする。両方使うて初めて数えられる）。
