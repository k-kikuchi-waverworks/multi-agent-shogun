# RCA: cmd_1274 ping-pong 再発 — better-sqlite3 Linux binary が殿 Windows `npm run test` で surface (B1 E2E中)

- **日時**: 2026-07-13（検知 20:45・将軍下知 20:45 → gunshi1 RCA 20:50-21:xx）
- **検知**: 殿 実機 `npm run test`（cmd_1274 B1 E2E runbook 項目1）で `sqljs-compat.test.ts` fail = **`better_sqlite3.node is not a valid Win32 application`**
- **RCA著者**: gunshi1（軍師一号・cmd_1274 B1 QC/runbook 継続担当・非設計著者）
- **分類**: node_modules platform-binary ping-pong の **再発 surface**（新規汚染に非ず＝B0 残渣の持越し）
- **先行 incident**: `logs/incidents/cmd_1274_wsl_install_ping_pong.md`（B0・16:37・lightningcss-win32 消失）の continuity
- **核心結論**: ★**真因＝H1（15:39 B0 起源の Linux binary 持越し）で確定。H2（16:37後の agent 再汚染）は binary mtime で明確に反証**★。将軍の当初前提「16:37後の再汚染」は**訂正**（適度な懐疑・feedback_verify_authority_claims）。**agent の R2 違反は 16:37以降ゼロ**。

---

## 0. 結論サマリ（家老・殿 向け3行）

1. **真因＝H1 確定**：better-sqlite3 の Linux binary は **15:39（B0 の WSL install）で生成され、以降一切書き換わっていない**（mtime 15:39 不変が5工程を貫通）。16:37以降の再汚染ではない。
2. **なぜ生き残ったか（深層根因）**：殿の Windows `npm install`（16:33・20:18 の2回）は**既存 present な native module を rebuild しない**ため、Linux binary が**両 install を素通りで持越し**。B1 cutover(3b68458)で getDb が better-sqlite3 を runtime load するようになり、**20:42 の `npm run test` で初めて surface**。
3. **殿 fix 最短手＝`npm rebuild better-sqlite3`**（Windows）。★**素の `npm install` では直らない**（20:18 の実測で証明済＝reify moves {}・binary 不変）★。

---

## 1. 真因の断定：H1 確定 / H2 反証（客観証拠）

### 1.1 決定的証拠 — binary mtime（憶測でなく file 物証）

```
node_modules/better-sqlite3/build/Release/better_sqlite3.node
  = ELF 64-bit LSB shared object, x86-64, GNU/Linux   ← Linux native
  = mtime Jul 13 15:39   ← B0 install 時刻（16:37 incident より前）
  = link count 2（obj.target/better_sqlite3.node と hardlink＝node-gyp 通常出力）
同ディレクトリ build artifacts:
  sqlite3.a / test_extension.node / obj/ / obj.target/ / .deps/  = すべて 15:38-15:39
  package dir (LICENSE/README/package.json/src/lib/deps)         = すべて 15:38
```

→ **15:38-15:39 の単一 coherent な node-gyp source compile**（prebuilds/ 不在＝source ビルド）。これは B0 commit `1f1b905`（15:49）に先行する ash4 の WSL `npm install`（better-sqlite3 を入れるため）に一致。

### 1.2 H1/H2 判定

| 仮説 | 内容 | 判定 | 根拠 |
|------|------|------|------|
| **H1** | 15:39 B0 起源の Linux binary が殿 recovery で未修復のまま**持越し** | ✅ **確定** | binary mtime **15:39 不変**。生成後5工程（16:33 win install / 19:50-19:56 WSL tsc-eslint / 19:53 B1 commit / 20:18 win install / 20:27-20:29 WSL tsc）を貫通しても mtime 不変＝**一度も rebuild されていない** |
| **H2** | 16:37後に agent が WSL install/rebuild で**再汚染** | ❌ **反証** | 再汚染なら .node の mtime が 16:37以降に更新されるはず。実測 **15:39 のまま**＝物理的に再汚染は起きていない。加えて 16:37以降の WSL npm ログは**全て tsc/eslint exec**（後述§2）で install/rebuild ゼロ |

★**将軍の「16:37後の再汚染」前提は訂正される**★。本件は再汚染ではなく、**B0 の Linux 残渣が殿の Windows recovery を2度素通りして持越した**もの。binary mtime は log 保持に依存しない物証ゆえ、この結論は log rotation の有無に関係なく確定的。

### 1.3 なぜ殿の Windows install（16:33・20:18）で直らなかったか — 深層根因

**npm reify は「既に present な native module」を rebuild しない。**

- 殿 16:33 install（Windows npm-cache log `07_33_02`＝`npm install` exit 0）→ `silly reify moves {}`（移動ゼロ）。better-sqlite3@12.11.1 は lockfile 通り present ゆえ**触らず**＝Linux binary 残存。
- 殿 20:18 install（Windows npm-cache log `11_18_41`＝`npm install` exit 0）→ 同じく `reify moves {}`。**find 実測でこの install が触ったのは `.package-lock.json`（+ root `package-lock.json`）のみ**、node_modules 内の実 package は不変＝better-sqlite3 rebuild されず。

**非対称性（＝better-sqlite3 が persistent offender、lightningcss は一発解消だった理由）**：

| 依存 | B0 WSL install での状態 | 殿 Windows install の挙動 | 結果 |
|------|------------------------|--------------------------|------|
| **lightningcss-win32-x64-msvc**（os-gated optional） | **prune/削除**された（win が os 不一致で omit） | **欠落→再追加**（install が missing を検知し導入） | ✅ Windows 復帰（16:37 recovery で解消） |
| **better-sqlite3.node**（compiled native、present） | Linux 版が**ファイルとして存在**（削除されず） | **present→skip**（name@version が lockfile 一致ゆえ satisfied 判定、install script 非実行、node-gyp 非起動） | ❌ Linux のまま持越し（rebuild しない限り不変） |

→ **削除された optional dep は再 install で戻るが、present だが platform 違いの compiled binary は再 install で戻らない**（npm は native binary の platform を検証しない＝name@version のみで satisfied 判定）。これが better-sqlite3 が ping-pong の**持続的な当たり屋**になる構造。

### 1.4 なぜ 20:42 まで顕在化しなかったか（latent → surface）

- 20:18 に殿は `npm install` 後すぐ `npm run dev:all`/`dev` を起動（Windows npm-cache log `11_18_49` x3）。**dev サーバは lightningcss(win 正常) を使うが better-sqlite3 を実 load しない**ため正常に見え、殿は「直った」と認識して先へ。Linux binary は **latent**。
- B1 cutover `3b68458` で `getDb → SqlJsCompatDb(better-sqlite3)` に切替＝**better-sqlite3 を runtime load する経路が成立**。
- 20:42 の `npm run test`（＝`vitest run`・B1 E2E runbook 項目1）で `sqljs-compat.test.ts` が native better-sqlite3 を load → **Windows loader が ELF(Linux) を拒否＝「not a valid Win32 application」** → surface。

これは B0 incident doc の予見（「install 段階で発火／runtime で surface」）通りの second wave。

---

## 2. Agent 監査（16:37以降・自己[gunshi1]含む・self-serving 申告を binary 物証と突合）

**監査基盤＝二系統の npm ログ**：
- WSL npm ログ `~/.npm/_logs/`（agent の WSL npm 操作が残る）
- Windows npm ログ `/mnt/c/Users/.../AppData/Local/npm-cache/_logs/`（殿の Windows npm 操作が残る・WSL とは別 store）

| 時刻(JST) | 主体 | 操作（ログ実測） | R2 判定 | binary 影響 |
|-----------|------|-----------------|---------|-------------|
| 15:38-15:39 | ash4 (WSL) | `npm install`（better-sqlite3 導入）→ node-gyp source compile = **Linux ELF 生成** | ★R2成立**前**★（本incidentがR2を生んだ。disciplinary違反に非ず） | **汚染起源** |
| 16:32-16:33 | 殿 (Windows) | `npm install`（B0 recovery・reify moves {}） | 正規（殿=Windows canonical installer） | 不変（present skip） |
| 19:50-19:56 | ash4/gunshi (WSL) | `npm exec eslint …` ×2 + `npm exec tsc --noEmit` ×4（B1 QC tooling） | ✅ **R2 遵守**（pure-JS tooling・install/rebuild なし） | 不変 |
| 19:53 | ash4 | commit `3b68458`（B1 cutover・code のみ） | ✅ | 不変 |
| 20:18 | 殿 (Windows) | `npm install`（reify moves {}）→ `npm run dev:all/dev` | 正規 | **不変**（.package-lock.json のみ touch） |
| 20:27-20:29 | ash4/gunshi (WSL) | `npm exec tsc --noEmit` ×5（QC tooling） | ✅ **R2 遵守** | 不変 |
| 20:42 | 殿 (Windows) | `npm run test`（vitest）→ exit 1（surface） | 正規（E2E runbook） | 不変（load のみ・書換なし） |

### 2.1 監査結論

- **16:37以降、engine 配下で WSL から `npm install`/`ci`/`rebuild`/`vitest`/`build`/`dev` を走らせた agent は存在しない**。WSL npm 活動は**全て `npm exec tsc --noEmit` / `npm exec eslint`**（R2 が許可する pure-JS tooling）。→ **post-R2 の R2 違反ゼロ**。
- **ash4**：唯一の WSL `npm install` は 15:38 の B0 install で、これは**R2 制定前**（R2 は本 incident を契機に生まれた）。以降は tsc/eslint のみ＝遵守。
- **ash5**（cmd_1267）：各 report が一貫して「vitest=WSL不可(ping-pong規律)ゆえ将軍Playwright/殿Windows手番」と明記＝WSL native-toolchain を自制。遵守。
- **gunshi1（自己監査・self-serving 申告を排して物証で）**：拙者の B1 QC/runbook 作業で node_modules を書き換える操作（npm install/rebuild/vitest）は**一切していない**。19:50-20:29 の WSL tsc/eslint exec には拙者由来分が含まれ得るが、これらは R2 許可 tooling であり binary を触らない。**binary mtime 15:39 が拙者の全活動に先行し、以降不変＝拙者は汚染に無関与**。自己に甘い判定でなく物証で clean。

### 2.2 誤帰責の回避

★**「16:37後に誰かが再汚染した」という帰責は成立しない**★。名指しで再汚染を犯した agent は**いない**。真因は「B0 Linux 残渣が npm install の rebuild-skip 仕様で持越した」構造であって、特定 agent の post-R2 の不作為/違反ではない。誤帰責を避けるべく、以上は log と binary mtime の物証のみで断定。

---

## 3. `.package-lock.json` 20:18 の出所（特定完了）

- **出所＝殿の Windows `npm install`（20:18）**。Windows npm-cache log `2026-07-13T11_18_41_269Z-debug-0.log` = `verbose title npm install` / `verbose argv "install"` / `cwd C:\Users\k-kikuchi\development\ai-automate-engine` / `exit 0`。
- **WSL 操作ではない**：`~/.npm/_logs` には 19:56→20:27 の間に**ログが1件も無い**（20:18 の WSL npm 操作は存在しない）。20:18 は Windows store 側にのみ記録。
- **R2 抵触なし**：殿の Windows install は canonical で規律違反に非ず。
- **効果**：`reify moves {}` の no-op install が `.package-lock.json` と root `package-lock.json` を**byte 同一で書き直し（mtime 20:18 のみ更新）**。git status clean が content 無変更を裏付け（＝これが「no-op npm install は lockfile mtime だけ bump する」典型痕跡）。
- **重要な副次証明**：この 20:18 `npm install` が better-sqlite3 を rebuild しなかった実測こそが、**§4 の「素の npm install では直らない」を経験的に証明**している。

---

## 4. Cutover code（3b68458）健全性の追認

- **sqljs-compat.test.ts の fail は 100% binary platform 起因**。`not a valid Win32 application` は Windows loader が **ELF(Linux) の .node を DLL として拒否**する OS レベルエラーであり、TypeScript/ロジックの欠陥ではない。node_modules 内の better_sqlite3 系 .node は**全て ELF Linux**（Windows PE binary は1つも存在しない）＝殿 Windows での load は必ず失敗する状態。
- **code は健全**：B1 は `getDb→SqlJsCompatDb(better-sqlite3)` の atomic 差替で、B0 の characterization parity（search_norm LIKE 全角/大小/濁点・API 8 面）が PASS 済＝sql.js API 忠実被覆。**better-sqlite3 を Windows 版へ rebuild すれば同一 code がそのまま pass する見込み**。
- **他3 fail は pre-existing**：executions-finalize/presentation-api（time/date 依存）は ash4 の stash baseline でも同一再現＝本 cutover 無関係（runbook 項目1判定通り）。
- → ★**将軍の「cutover code健全＝binary起因のみ・殿 Windows rebuild で pass 見込み」判定を追認**★。B0/B1 の revert は不要。

---

## 5. 恒久防止の技術策（提言）

### 5.1 (a) 殿 Windows fix — 最短手

| 手段 | 可否 | 理由 |
|------|------|------|
| ❌ `npm install` | **効かない** | present skip で better-sqlite3 を rebuild しない（20:18 実測で証明済＝reify moves {}・binary 不変）。再実行しても同じ no-op |
| ✅ **`npm rebuild better-sqlite3`** | **推奨・最短** | 当該 package の install/build lifecycle を**強制再実行**。better-sqlite3 は `prebuild-install`（依存に実在＝audit で 7.1.3 確認）を持つため、`prebuild-install`（Windows prebuilt DL・**コンパイラ不要**）→ 失敗時 node-gyp compile へ fallback |
| ✅ 代替 | delete → install | `Remove-Item -Recurse node_modules\better-sqlite3` → `npm install`（fresh install で install script 再走＝prebuild-install が Windows binary DL）。VS Build Tools 無くても可 |

**殿への提示（コピペ・Windows PowerShell、`C:\Users\k-kikuchi\development\ai-automate-engine` で）**：
```powershell
npm rebuild better-sqlite3      # ← これで Windows 版 .node を再生成
npm run test                    # ← sqljs-compat.test.ts が pass するか再確認
```
これで直らない（コンパイラ不足等）場合の fallback：
```powershell
Remove-Item -Recurse -Force node_modules\better-sqlite3
npm install                     # prebuild-install が Windows prebuilt を取得
npm run test
```
★核心メッセージ＝**「present だが platform 違いの native は rebuild を強制しない限り直らない。素の `npm install` は no-op」**★。

### 5.2 (b) R2-1 の task 発行時強制注入（家老 Ashigaru Dispatch Template 用・文言案）

engine 系（`project: ai-automate-engine` or `repo_path` が ai-automate-engine を含む）の全 task YAML に、家老 dispatch script が**自動注入する必須 section**：

```markdown
## 🚫 R2-1（engine native-toolchain WSL 絶対禁）— cmd_1274 ping-pong 起源
engine(ai-automate-engine) 配下で WSL から下記を実行してはならない（native binary を
linux 版へ書換え殿 Windows を破壊＝ping-pong 再発）:
  npm install / npm ci / npm rebuild / npm update / npm run test / test:watch /
  npm run build / npm run dev / dev:all / db:* / vitest / npx tsx（native load 経路）
✅ WSL 許可（pure-JS/read-only のみ）: npm exec tsc --noEmit / npm exec eslint /
  read / ls / file / git
✅ install/rebuild/test/build/dev/db seed = 殿 Windows 手番。
  依存追加時: package.json/lock 編集(AI) → install 実行は殿 Windows（task YAML に
  「install=殿Windows手番」を明記）。
```

- **格上げの要点**：従来 R2 は「規律 doc に書いてある」水準だったが、cmd_1274 で連続 surface した通り**未注入の task では守られない**。家老が dispatch 時に engine 系 task へ**機械的に注入**（任意でなく必須 field 化）することで、足軽が task YAML 単体で完結認識しても R2-1 が視界に入る。

### 5.3 (c) WSL 側 native rebuild を構造的に不可能化する策（推奨＝root preinstall guard）

規律（人/AI の遵守頼み）を超えて**構造的に**塞ぐ案。engine package.json に **preinstall guard**（現状 preinstall 無し＝追加は非衝突）：

```json
// package.json "scripts" に追加
"preinstall": "node scripts/guard-no-wsl-install.js"
```
```js
// scripts/guard-no-wsl-install.js（新設・commit 対象＝durable/OSS共有可）
const fs = require('fs');
if (process.platform === 'linux') {
  let wsl = false;
  try { wsl = /microsoft/i.test(fs.readFileSync('/proc/version', 'utf8')); } catch {}
  if (wsl || process.platform === 'linux') {
    console.error('\n🚫 R2-1: このengineは Windows-canonical。WSL/Linux での npm install/ci は');
    console.error('   native binary ping-pong を起こすため禁止です（cmd_1274）。');
    console.error('   install は殿 Windows 手番で。WSL は tsc/eslint/read のみ。\n');
    process.exit(1);
  }
}
```

| 特性 | 評価 |
|------|------|
| 効果範囲 | `npm install`/`npm ci`（preinstall 起動）を **WSL/Linux から caller 問わず hard-block**。人 agent 双方に効く |
| Windows 素通り | `process.platform==='win32'` ゆえ殿の Windows install は通る |
| tooling 非干渉 | `npm exec tsc`/`npm run lint`（＝eslint）は preinstall を起動しないため妨げない |
| durable/共有 | package.json+script を commit＝session を跨いで永続、OSS fork にも載る |
| 死角 | `npm rebuild <pkg>`（root preinstall 非起動）は塞げない。→ **defense-in-depth**：(b) R2-1 template + 下記 WSL npm wrapper を併用 |

**併用推奨の WSL npm wrapper（agent の WSL profile に・任意）**：engine 配下で `npm install|ci|rebuild|update` を叩いたら reject し、`npm exec|run tsc|lint` は許可する shell function。preinstall guard が塞げない `npm rebuild` を補完。ただし絶対 path 呼び出しで回避され得るため**主軸は preinstall guard、wrapper は補助**と位置付ける。

**長期の真の恒久解**（incident doc §恒久解と整合）＝**Windows-canonical node_modules 単一化**（install は殿 Windows のみ・WSL は install しない）。preinstall guard はこの規律を**構造で担保**する第一歩。

---

## 6. 暗黙前提チェックリスト結果（軍師 MANDATORY）

| 項目 | 明記/判定 | 備考 |
|------|-----------|------|
| リソース配置 | ✅ | engine node_modules は C:\ 共有 tree（Windows/WSL 同一実体）＝ping-pong の物理前提 |
| VRAM/メモリ | N/A | 本件は binary platform 問題・GPU 無関係 |
| ネットワーク | ✅ | fix の prebuild-install は GitHub releases から Windows prebuilt DL（殿 Windows のみ） |
| 権限・認証 | ✅ | install 実行主体を殿 Windows に限定（canonical installer）＝R2-1 の核 |
| 障害時挙動 | ✅ | fix fallback（rebuild 失敗→delete+install）を §5.1 に明記 |
| スケール前提 | N/A | — |
| 運用オペ | ✅ | 殿コピペ手順 + 家老 template 注入 + preinstall guard を提示 |
| コスト前提 | ✅ | prebuild DL は無償・compile も local。課金操作なし |

---

## 7. 参照

- `logs/incidents/cmd_1274_wsl_install_ping_pong.md`（B0 incident・R2 起源）
- commit `1f1b905`（B0 adapter・better-sqlite3 導入）/ `3b68458`（B1 cutover）
- `plans/cmd_1274_db_migration_design.md` R2 改訂（Windows-canonical 恒久解）
- 証拠ログ: `~/.npm/_logs/`（WSL・全て tsc/eslint exec）/ `/mnt/c/Users/k-kikuchi/AppData/Local/npm-cache/_logs/`（Windows・16:33 install / 20:18 install / 20:42 test）
- memory: [[project_engine_db_migration_strategy]] / [[feedback_verify_before_assert]] / [[feedback_verify_authority_claims]] / [[ops_engine_windows_canonical_npm]]
