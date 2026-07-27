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

## 7. 今 赤い 3 本（本任の外・誰かが見るべき物）

```
src/lib/__tests__/no-disclaimer.test.ts
src/lib/__tests__/stocks-ingest-prices-live.test.ts
src/lib/__tests__/stocks-ingest-supply-demand-deep.test.ts
```

中身を1つだけ挙げる。`eodStepsForSlot("PM")` が返す手順が、テストの期待より 1 つ多い
（`impact` が増えている）。code が先に進み、テストが追い付いていない形である。
**これは今日 テストが1本も走っていなかったことの直接の証拠**であり、
走る道ができた以上、誰かが片付ける必要がある。四号の任の外ゆえ、家老へ上げる。

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

## 10. 一言でいうと

R2-1 の禁は **npm を通る道**にかかっている。node.exe で vitest を直に呼ぶ道は禁の外であり、
実測でも repo・依存・本番 DB のどれも触らない。
**ゆえに「engine にテストが書けぬ」理由は、今日をもって「禁じられている」から「誰も撃っていない」へ移った。**
