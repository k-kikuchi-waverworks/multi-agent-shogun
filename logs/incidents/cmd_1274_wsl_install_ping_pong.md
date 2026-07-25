# Incident: cmd_1274 B0 WSL npm install → lightningcss win binary 消失 → 殿 Windows dev 破壊 (node_modules ping-pong)

- **日時**: 2026-07-13
- **検知→RCA→記録**: 殿 実機(`npm run dev` CssSyntaxError)→将軍 RCA→gunshi2(cmd_1274 設計著者)記録
- **分類**: engine=Windows-canonical 規律違反 (`ops_engine_windows_canonical_npm`) + native optionalDependency os-gating による ping-pong
- **核心教訓**: ★将軍が cmd_1274 最重要リスクと挙げた「native binding Win/WSL 割れ」が、runtime でなく **`npm install` 段階** で即発火した実例★。gunshi2 設計 (R0/R1) は runtime 側の binding 割れを分析したが、**install 段階の optional-dep os-pruning による巻き添え**を書き落としていた (設計の穴)。

## 何が起きたか

殿 Windows で `npm run dev` が **`Cannot find module '../lightningcss.win32-x64-msvc.node'` → CssSyntaxError** で起動不能に。engine (Next/Tailwind v4) の CSS 変換ネイティブ依存 `lightningcss` の Windows binary が node_modules から消えていた。

## 根本原因 (将軍 RCA・gunshi2 実裏取り済)

1. **B0 commit `1f1b905`** (cmd_1274 B0=`SqlJsCompatDb` adapter + create_function shim) が **package.json に `better-sqlite3 ^12.11.1` + `@types/better-sqlite3` を追加** (実確認: `git show 1f1b905 --stat` / package.json:36,55)。★B0 は adapter を「作って検証」までで db.ts 非改変=production 経路は現行 sql.js のまま非破壊★。
2. ash4 が **engine 配下 (C:\ 共有 node_modules) で WSL(linux) から `npm install`** を実行 (better-sqlite3 を入れるため)。
   - (a) `better-sqlite3` が **linux 用 native build** で入る。
   - (b) ★同じ install が **optionalDependencies を os で再解決**★: package.json は `lightningcss-linux-x64-gnu` と `lightningcss-win32-x64-msvc` を **両 os 宣言済** (package.json:49-51) だが、npm は **現 os(linux) に一致する `lightningcss-linux-x64-gnu` のみ install し、`lightningcss-win32-x64-msvc` を os 不一致で prune/omit**。→ 殿 Windows dev が要する `lightningcss.win32-x64-msvc.node` が node_modules から消失。
3. 結果、殿 Windows `npm run dev` の Tailwind/lightningcss CSS 変換が win binary を見つけられず CssSyntaxError。

## 規律違反

- `ops_engine_windows_canonical_npm` = ★engine は Windows-canonical・WSL での build/install は禁★。ash4 が engine 配下で WSL `npm install` を実行したことが直接の引き金。
- 依存追加 (package.json 編集) と `npm install` 実行が **同一 agent(WSL)で連続**したため、Windows 側 binary が巻き添えで pruned された。

## 影響と対応

- **影響**: 殿 Windows dev サーバ起動不能 (一時)。★engine コードは無傷 (B0 は db.ts 非改変=非破壊)・DB データ無傷★。被害は node_modules の platform binary 状態のみ。
- **対応**: (1)殿 手番で **Windows `npm install` 復旧** (将軍案内済)→win32 binary 復帰 (現状実確認: `lightningcss-win32-x64-msvc` 在 / linux-x64-gnu 不在=Windows state に復旧済)。 (2)★全 ash 徹底=engine 配下での WSL `npm install`/`npm rebuild`/`npm ci`/依存 install 禁★=package.json/lock 編集は AI・**install 実行は殿 Windows 手番** に厳格分離。 (3)恒久策=cmd_1274 設計 R2 amendment (install 規律 + node_modules ping-pong 恒久解=Windows-canonical node_modules 単一化)。 (4)本 RCA 記録。
- **B0 revert 不要**: `1f1b905` は db.ts 非改変・非破壊ゆえ code revert 不要。package.json の better-sqlite3 依存は残置し、install は殿 Windows で行う。

## ping-pong 構造 (再発防止の本質)

★engine node_modules は C:\ に在り Windows/WSL が **同一 tree を共有**★。native / os-gated optional 依存 (better-sqlite3・**lightningcss**・esbuild・oxide 等) は install 時に **現 os の binary のみ導入し他 os 版を prune** する。ゆえ:

- **WSL agent** が install → linux binary 状態 → 殿 Windows dev 破壊 (win binary 消失)。
- **殿 Windows** が install → win binary 状態 → WSL agent の vitest/build が破壊 (linux binary 消失=cmd_641 esbuild TransformError と同型)。

= 両者が同一 node_modules を奪い合う **ping-pong**。★両 os 宣言 (optionalDependencies に両方書く) でも npm の os-gating が非現 os を prune するため解決しない (本 incident が実証: 両宣言済なのに win が pruned)★。

## 恒久解 (cmd_1274 R2 で確定)

**単一推奨=Windows-canonical node_modules 単一化**: engine node_modules は殿 Windows install が唯一の正=WSL agent は **install しない** (package.json/lock 編集まで)。WSL agent は pure-JS tooling (`tsc --noEmit`/eslint/read/design) のみ。native-toolchain 実行 (vitest[esbuild]/Next build[lightningcss]/DB integration) は **殿 Windows 手番 (or 将来 Windows CI)**。→ WSL は install/prune しないゆえ ping-pong が構造的に消える。詳細・却下案 (WSL overlay / 両 platform binary) の根拠は `plans/cmd_1274_db_migration_design.md` ★★改訂 R2★★ 参照。

## 再発防止

1. ★engine 配下で WSL `npm install`/`rebuild`/`ci` を絶対に実行しない (全 ash 徹底)★。依存追加=package.json/lock 編集(AI)→ `npm install` は殿 Windows 手番。
2. native 依存 (better-sqlite3 等) を追加する cmd では、task YAML に「install=殿 Windows 手番」を明記し AI が install しない。
3. cmd_1274 B1 atomic cutover の殿承認 gate に本 install 規律 + ping-pong 恒久解を必須条件として含める。
4. 教訓の一般化=「native binding Win/WSL 割れ」は runtime だけでなく **install 段階の optional-dep os-pruning** でも発火する (設計時に install 経路も想定せよ)。
