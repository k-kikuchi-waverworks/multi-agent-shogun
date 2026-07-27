# engine のテストを WSL から安全に走らせる道 (cmd_1422)

測定者: 足軽四号 / 測定日時: 2026-07-27 19:25〜19:30 JST / 対象: `C:\Users\k-kikuchi\development\ai-automate-engine`

---

## 1. 結論 — この1行を貼れ

```bash
cd /mnt/c/Users/k-kikuchi/development/ai-automate-engine && \
  node.exe node_modules/vitest/vitest.mjs run --reporter=dot --no-color --no-cache
```

WSL の bash にそのまま貼る。1ファイルだけ撃つなら末尾にパスを足す。

```bash
cd /mnt/c/Users/k-kikuchi/development/ai-automate-engine && \
  node.exe node_modules/vitest/vitest.mjs run src/lib/stocks/interpret/__tests__/earnings.test.ts \
  --reporter=dot --no-color --no-cache
```

**成功した時の見え方**（実測・全115ファイル）:

```
 Test Files  3 failed | 112 passed (115)
      Tests  3 failed | 1617 passed (1620)
   Duration  9.74s
```

所要は約 10 秒。`npm` は一度も通らない。

**注意**: 今この時点で 3 本が赤である（下の §7）。**赤が 3 本のままなら、それは貴殿のせいではない。**
自分の変更で増えたかを見るには、撃つ前と後の赤の数を比べること。

---

## 2. 何を測ったか（母数を先に）

| 測った物 | 母数 |
|---|---|
| node_modules の中身 | 32,227 エントリ（パス・サイズ・更新時刻を全件） |
| native の実体（`.node`） | 17 ファイルの md5 |
| 定義ファイル | package.json / package-lock.json / vitest.config.ts / tsconfig.json の md5 |
| 本番 DB | data/automate-engine.db（12.5GB）と -wal / -shm のサイズと更新時刻 |
| repo の作業木 | `git status --porcelain` の行数 |
| engine の生死 | 38080 への HTTP |

撃った回数は 5 回（1ファイル×3・全件×2）。node.exe は v24.13.1、vitest は 4.1.9。

---

## 3. 家老が挙げた3点 — 3つとも通った

`--no-cache` を付けた形での実測である。

| 確かめる所 | 結果 | 数 |
|---|---|---|
| (a) node_modules に1バイトも書かぬ | **通った** | 32,227 件中 変化 0 件。撃った時刻より新しいファイルも 0 件 |
| (b) native を作り直さぬ | **通った** | 17/17 の md5 が一致 |
| (c) package-lock / package.json に触れぬ | **通った** | 4ファイルとも md5 一致 |

自分で足した2点も通った。こちらの方が実害としては重い。

| 追加で確かめた所 | 結果 |
|---|---|
| (d) 本番 DB（12.5GB）を触らぬ | 通った。サイズも更新時刻も 5 回撃った後で不変 |
| (e) repo に差分を残さぬ | 通った。`git status` は前後とも 0 行 |
| (f) engine を落とさぬ | 通った。撃つ前も後も 38080 が http=200 |

(d) を足した理由: テスト 115 本のうち 49 本が `@/lib/db` を読み込む。
そのうち 48 本は `vi.mock` で差し替えており、残る 1 本（stocks-migrate）は
sql.js のメモリ内 DB を使う。**よって本番 DB を開くテストは 0 本**である。
ただし読んで確かめただけでは足りぬので、12.5GB のファイルの更新時刻を前後で比べた。

---

## 4. `--no-cache` は飾りではない — 付けねば (a) が崩れる

`--no-cache` を外して同じ全件実行を撃つと、**1ファイルだけ書き込みが起きる**。

```
node_modules/.vite/vitest/da39a3ee5e6b4b0d3255bfef95601890afd80709/results.json
  サイズ 10383 (不変) / 更新時刻のみ変わる
```

vitest が自分の結果キャッシュを node_modules の下に置くためである。
中身は依存パッケージではなく vitest 自身の作業ファイルだが、
**「node_modules に1バイトも書かぬ」を文字どおり満たすのは `--no-cache` を付けた時だけ**である。

失う物: 前回の結果を使った並び替えができなくなる。全件で 10 秒ゆえ、実害は無い。

### 計器が本当に効いていることの確かめ（変異）

「変化 0 件」は、計器が何も見ていなくても同じ顔で出る。
ゆえに `--no-cache` を外した実行で計器を撃った。結果、**32,227 件のうち
更新時刻だけが変わった 1 件を名指しで検知した**。よって「0 件」は
見ていない側の 0 ではない。

---

## 5. 撃てる物・撃てぬ物

### 撃てる（実測）

**全115ファイル・1620テストが撃てる。SKIP は 0 本。**

家老の見立て「native を要するテストは撃てぬはず」は**外れている**。実測すると:

| native | node.exe (v24) で | 実際に使うテスト |
|---|---|---|
| better-sqlite3 | 動く（:memory: に読み書きまで確認） | sqljs-compat.test.ts・instrument.test.ts = 19/19 緑 |
| sharp | 読み込める | — |
| node-pty | 読み込める | — |

`src/lib/stocks/__tests__/instrument.test.ts` の冒頭には
「実行は殿 Windows 手番（WSL は better-sqlite3 / vitest rolldown native 不可）」と書かれているが、
**この注記は今日の測定で古くなった**。正しくは「WSL 側の node では不可・node.exe なら可」である。

### 撃てぬ

今日の測定の範囲では、撃てぬテストは見つかっていない。
ただし下の §8 に「測っていない事」を列記した。**「撃てぬ物は無い」とは書かない。**

---

## 6. WSL 側の node で撃つな — エラーが禁を踏ませに来る

WSL の `node`（v20）で同じことをすると、こうなる。

```
$ node node_modules/vitest/vitest.mjs run ...
Error: Cannot find native binding. npm has a bug related to optional dependencies.
       Please try `npm i` again after removing both package-lock.json and node_modules directory.
  cause: Cannot find module '@rolldown/binding-linux-x64-gnu'
```

**★このエラー文そのものが罠である。★**
言われたとおり `npm i` を撃てば R2-1 に真正面から違反し、殿の環境が壊れる。
node_modules に入っているのは Windows 版のバイナリだけであり、Linux 版は元より無い。
**ここで npm を撃つな。node.exe に持ち替えよ。**

同じ形をもう一つ。WSL の node で better-sqlite3 を読むと、こうなる。

```
step1 require: OK
step2 construct: FAIL: .../better_sqlite3.node: invalid ELF header
```

**読み込みは通り、使うと落ちる。** 「読めた」を「動く」の代わりに使えぬ実例である。

---

## 7. 赤かった 3 本 — 中身と、どちらが誤りかの判定（19:36〜19:41 に片付けた）

道が開いた時点で 3 本が赤であった。**これは今日まで1本も走っていなかったことの直接の証拠**ゆえ、
中身をそのまま残す。1 本ずつ「code とテストのどちらが誤りか」を判じてから直した。
**テストを code に合わせて黙らせた物は 1 本も無い。**

| # | 赤かったテスト | 中身 | 判定 |
|---|---|---|---|
| 1 | `no-disclaimer.test.ts` | `EarningsSubstancePanel.tsx:16` の**設計コメント**「投資助言ゼロ（事実の提示まで…）」を免責文言として検知 | **テストの射程が広すぎた（誤検知）** |
| 2 | `stocks-ingest-prices-live.test.ts` | `runPricesIngest` の戻り値に `unconfirmedCut: ""` が増えた。テストは完全一致で 3 欄だけを期待 | **テストが古い。code が正しい** |
| 3 | `stocks-ingest-supply-demand-deep.test.ts` | `eodStepsForSlot("PM")` の手順が 1 つ多い（末尾に `impact`） | **テストが古い。code が正しい** |

### #1 の根拠 — なぜ「テストが誤り」と判じたか

この門が撤去する対象は `docs/stocks-support.md` に書かれている。
**「CYA 文言は全撤去済／silent backend・UI で説教しない」** ＝ **殿の画面と prompt に出る文言**である。
赤くしていたのは source のコメント 1 行で、画面にも prompt にも出ない。狙いに当たらない。

直し方：`.ts` / `.tsx` の**コメントだけの行**を走査から外した。狭めたのはそこだけである。

- 行末コメント（code と同じ行）は今までどおり拾う
- `.md`（`prompts/stock-*`）は**全行を走査したまま** ＝ LLM への指示文そのものゆえ
- 狭めた事自体を守るテストを 1 本 足した（`it("射程を狭めた所だけが通る…")`）

**壊せば赤くなるかを撃った**（一時ファイルを置いて即消す形・作業木は 0 行に戻した）。

| 撃った物 | 結果 |
|---|---|
| 走査対象の `.ts` に**通常の行**で「本ツールは投資助言ではありません」 | **赤（ファイル名と行番号を名指し）** |
| 同じ文言を**コメント行**に置く | 緑（＝狭めた所が意図どおり通る） |

### #2 の根拠

`unconfirmedCut` は cmd_1369b/c/e で意図して足された欄である（「未確定の当日を切ったのに、切ったと言えていなかった」を直した物）。
このテストは `asOf=2026-07-12` ＝ 確定日以前ゆえ**切っていない** ＝ 空文字が正しい挙動である。
期待値に `unconfirmedCut: ""` を足した。

**完全一致（`toEqual`）のまま残した。** 欄が増えた事に気付けたのはこの形だったゆえ、
`toMatchObject` へ緩めれば次に欄が増えた時に誰も気付けなくなる。

### #3 の根拠

`impact` は cmd_1351 第2次で意図して足された手順である。
「impact-backfill には code 内の呼び手が 0 人で、人が HTTP を叩いた日にしか進まなかった」を塞ぐ物で、
位置にも理由がある（材料を入れる 3 手順より後・discovery より前）。末尾へ足しただけで既存の順序は動いていない。

このテストが守っているのは**手順の名前と相対順序**であって件数ではない。
ゆえに期待値へ `impact` を足し、**題から「9 step」という手書きの数を外した**。
同じ理由で `dailyEod.ts` のコメントに残っていた「7 step」も外した（足すたびに腐り、現に腐っていた）。

### 直した後（実測 19:41）

```
 Test Files  115 passed (115)
      Tests  1621 passed (1621)
   Duration  9.44s
```

SKIP 0。node_modules への書き込み 0 件、package.json / package-lock.json の md5 一致、engine は http=200 のまま。
テストが 1620 → 1621 に増えたのは #1 で門を守るテストを 1 本 足したためである。

---

## 8. 言えぬ側

家老の作法（⑦-a / ⑦-b / ⑦-c）で分けて書く。

- **「キャッシュが空の状態でも書き込み 0 か」について ⑦-b（安い道が無い）。**
  今日測ったのは `node_modules/.vite/` が既に在る状態である。中身は `vitest/` だけで
  `deps/`（vite の依存最適化の置き場）は無かった。ゆえに依存最適化は走っていないと見てよいが、
  `.vite` を消してから測るには**まず消すという書き込みが要る**ゆえ、測っていない。
  初めて撃つ人の環境では 1 ディレクトリ増えうる。

- **「テストが外へ通信していないか」について ⑦-b（高い）。**
  読んだ限りでは fetch も child_process も差し替えられているが、
  実際に通信を捕まえて数えたわけではない。捕まえるには packet の記録が要る。

- **「他の作業者が同時に撃った時どうなるか」について ⑦-c（当たらぬ）。**
  vitest は自分の作業ファイルを1つ書くだけで、それも `--no-cache` で消える。
  同時に撃っても判定は動かぬ。

- **殿の環境の他の部分について ⑦-b（種類として無理）。**
  測ったのは engine の repo と node_modules と DB である。
  Windows 全体に何も書いていないことは、この道具立てでは証明できない。

---

## 9. 再現の仕方（計器そのもの）

```bash
cd /mnt/c/Users/k-kikuchi/development/ai-automate-engine
T0=$(date -u +%s)
find node_modules -printf '%p|%s|%T@\n' | sort > /tmp/nm_before.txt
md5sum package.json package-lock.json > /tmp/pkg_before.txt
find node_modules -name "*.node" | sort | xargs md5sum > /tmp/native_before.txt
stat -c '%n %s %Y' data/automate-engine.db data/automate-engine.db-wal > /tmp/db_before.txt

node.exe node_modules/vitest/vitest.mjs run --reporter=dot --no-color --no-cache

find node_modules -printf '%p|%s|%T@\n' | sort | diff /tmp/nm_before.txt -   # 差分 0 が正
find node_modules -newermt @$T0 | wc -l                                      # 0 が正
md5sum -c /tmp/pkg_before.txt ; md5sum -c /tmp/native_before.txt
stat -c '%n %s %Y' data/automate-engine.db data/automate-engine.db-wal | diff /tmp/db_before.txt -
git status --porcelain | wc -l                                               # 0 が正
```

**新しく何かを撃つ時は、この形で前後を挟め。** 「たぶん読むだけ」で撃つな。

---

## 10. 次の段 — 誰が いつ走らせるか（案・家老の裁を仰ぐ）

**殿の手番は 0 である。**（管理者権限も、殿の画面での操作も要らない。導入も撤去も我らの手で足りる。）

今は「撃てる」が「撃たれる」になっていない。撃つ人を規律で決めても、今日の 3 本と同じ形で腐る。
ゆえに**commit の直前に機械が撃つ形**を推す。単一案である。

| | 内容 |
|---|---|
| 置く物 | engine 側の `pre-commit` フック（中身は §1 の 1 行 ＋ 落ちたら commit 中止） |
| 費え | commit 1 回につき約 10 秒 |
| 撃つ人 | 誰も撃たない。commit する者の手元で勝手に走る |
| 殿の手番 | **0** |
| 逃げ道 | 急ぎの時は `git commit --no-verify`。ただし**使ったら報告に書く**こと |

フックは `.git/hooks/` に置かれ git 管理外ゆえ、**作業木ごとに 1 回 入れる要がある**。
入れる 1 行（導入スクリプト）は repo へ置く。入っているか自体を検める口も要る
（入っていない作業木では黙って何も走らない ＝ 今日の「0 件は見ていない側の 0」と同じ形になるため）。

**採らなかった案とその理由**：定期実行（タスクスケジューラ）は、赤が出た時に**誰の変更で赤くなったか**が
分からない。commit の直前なら、赤くしたのは今 commit しようとしている者だと確定する。

## 11. 一言でいうと

R2-1 の禁は **npm を通る道**にかかっている。node.exe で vitest を直に呼ぶ道は禁の外であり、
実測でも repo・依存・本番 DB のどれも触らない。
**ゆえに「engine にテストが書けぬ」理由は、今日をもって「禁じられている」から「誰も撃っていない」へ移った。**
