---
name: shogun-decision-triage
description: 殿向け判断棚卸スキル。溜まった未決事項を「実態照合→backlog4層分類→1個ずつ殿判断(GO/NG/後で)→適用」の対話フローで一掃する。task-review(洗い出し)とquality-gate(品質ゲート)を内部活用し、その上に1個ずつ判断する対話層を載せる。「判断棚卸」「タスク整理」「status整理」「レビュー溜まってる」「他にもあるかも」「未決まとめて」で起動。Do NOT use for: 単発cmdの状態確認(それは/backlog)・詰め残しの調査だけ(それは/task-review)。
argument-hint: "[filter: recent | project:xxx | empty=all]"
disable-model-invocation: false
---

# /shogun-decision-triage — 判断棚卸 (殿の未決事項を対話で一掃)

## North Star

殿に溜まった「承認待ち・決定待ち・是正待ち・物理手番待ち」を**1個ずつ提示して即断即決**で片付ける。
判断を山積みのまま見せて殿を圧倒するのではなく、文脈を要約し GO/NG/後で の三択に落として、決まった分から確実に前へ進める。

memory整合: `feedback_verify_before_assert`(済と書く前に実データ確認) / `feedback_dashboard_path_accuracy`(YAML正本・dashboardは家老要約) / `feedback_avoid_default_hybrid`(単一案を推す) / `feedback_skill_registration_default_approve`。

## When to Use

- 「判断棚卸」「タスク整理」「status整理」「レビュー溜まってる」「他にもあるかも」「未決まとめて片付けたい」と言われた時
- 設計完遂→殿レビュー待ちの cmd が複数溜まっている時
- dashboard 🚨要対応 が積み上がり、殿が「一気に捌きたい」時

**他スキルとの棲み分け**:
| スキル | 役割 |
|--------|------|
| `/backlog` | 「今どうなっているか」状態スナップショット (4バケット表示) |
| `/task-review` | 「何を取りこぼしたか」詰め残し監査 |
| `/quality-gate` | 「品質ゲートを通ったか」個別cmd検証 |
| **`/shogun-decision-triage`** | **「溜まった未決を1個ずつ殿が捌く」対話型の決裁フロー** ← 上記3つを内部で使い、判断層を載せる |

## Instructions

以下の **4ステップ** を順に実行する。各ステップは前段の出力を入力とする。

---

### Step 1: 実態照合 (reality reconciliation)

未決事項の母集団を、推測でなく**実データ**から構築する。車輪の再発明を避け、既存スキルを内部活用する。

1. **`/task-review`** を内部実行 (`$ARGUMENTS` をそのまま渡す)
   → 詰め残し・Phase放置・テスト漏れ・status不整合・skill候補を網羅取得
2. `queue/shogun_to_karo.yaml` を SSoT として通読し、open cmd (status≠done) を抽出
3. `dashboard.md` の 🚨要対応 セクションを読み、殿手番項目を補完 (dashboardは家老要約=二次データ。必ずYAMLで裏取り)
4. `queue/reports/` の最新レポートで `outstanding` / `recommendation` / `next_steps` / `skill_candidate` を拾う
5. 各 open 項目を実態タグで分類:

| 実態タグ | 判定基準 |
|---------|---------|
| `done` | 実装+QC+(必要なら)commit 完了。残作業なし |
| `in-progress` | 足軽/軍師が作業中。殿の手番ではない |
| `設計完遂・殿レビュー待ち` | 軍師が plans/ に設計完遂、実装は殿承認待ち |
| `殿決定待ち` | 方針・採否の判断が殿に必要 (断定不能) |
| `殿物理手番待ち` | push / Windows UI確認 / 実機聴取 等 AI不可の手作業待ち |
| `bookkeeping不整合` | dashboard完了だがYAML status古い等、是正のみ |
| `stale` | 長期放置・前提崩れ・重複。要棚卸 |

**盲目done化禁**: 「dashboardに完了と書いてある」だけで done 扱いしない。`done`(全完了) / `AI完遂・殿手番残` / `殿手番待ち` を必ず区別する (memory `feedback_lora_qc_base_mismatch_lesson` の "load成功≠機能" と同型の戒め)。

---

### Step 2: backlog 4層分類 (4-layer triage)

Step 1 のうち**殿の手番が要る項目だけ**を、対応アクションが同型の4層に振り分ける。`done` / `in-progress` は対象外 (殿判断不要)。

| 層 | 名称 | 中身 | 適用アクション(Step 4) |
|----|------|------|----------------------|
| **A** | 殿レビュー・設計承認 | 軍師設計完遂→実装GOを仰ぐ (要対応#設計レビュー行列) | GO→家老へ実装cmd dispatch |
| **B** | 殿決定 | 方針/採否/優先度の意思決定 | 決定→memory記録 + 必要なら後続cmd起票 |
| **C** | bookkeeping是正 | status不整合・dashboard古い・重複クローズ | 是正リスト化→**家老が一元適用** |
| **D** | 物理手番 runsheet | push / Windows実行 / 実機確認 等 | phase分け runsheet に束ねて殿へ提示 |

任意で品質確認: A層で「実装GO前に品質ゲートを見たい」cmd は **`/quality-gate cmd_XXX`** を内部実行し、結果を提示材料に添える。

分類結果をまず一覧で表示してから Step 3 へ:

```
## 判断棚卸 — 対象 {N}件 ({今日の日付})

### A. 殿レビュー・設計承認 ({n}件)
| cmd | 内容 | 設計doc | 待ち |
### B. 殿決定 ({n}件)
| cmd | 論点 | 選択肢 |
### C. bookkeeping是正 ({n}件) ← 家老一元適用
| cmd | 現status | あるべき | 裏取り根拠 |
### D. 物理手番 runsheet ({n}件)
| cmd | 手作業 | stack依存 |
```

---

### Step 3: 1個ずつ提示 (interactive one-by-one judgment)

A層・B層を **1項目ずつ** 殿に提示する。C層は是正案として一括確認、D層は runsheet として最後にまとめる (これらは個別の即断不要)。

各 A/B 項目について:
1. 設計doc(plans/)・cmd定義・関連reportを読み、**論点と推奨を3〜5行に要約** (memory `feedback_avoid_default_hybrid`=安全策の定型ハイブリッドに逃げず単一案を推す)
2. `AskUserQuestion` で三択を提示:
   - **GO** — 承認。Step 4 で適用
   - **NG** — 却下/中止。理由を聞き、cmd を defer/close
   - **後で** — 保留。`status: deferred` + `defer.autopull` 設定の判断を仰ぐ
3. 殿の回答を控える (cmd id → 判断 → 補足)

**提示テンプレ (1項目)**:
```
【A-1】cmd_XXXX: {タスク名}
状況: {設計完遂の中身・誰が設計したか}
論点: {実装GOで何が動くか / 残リスク}
推奨: {GO推奨か・代替案があれば1つ}
→ GO / NG / 後で ?
```

対話を**殿のペースで**進める。一度に全部聞かず、A-1の判断を受けてからA-2へ。殿が「まとめて」と言えば数件束ねてよいが、既定は1個ずつ。

---

### Step 4: 適用 (apply)

殿の判断を実アクションに変換する。**status反映は家老が一元適用** (RACE回避。足軽/将軍が `shogun_to_karo.yaml` を直接編集しない — memory `feedback_2_gunshi_terminated` のdispatch整合と同じくファイル競合を避ける)。

| 判断 | 適用 |
|------|------|
| A=GO | 家老へ「cmd_XXX実装dispatch」を inbox_write (実装タスクYAML起票は家老) |
| A/B=NG | 家老へ status→done(中止記録) or deferred 反映を依頼 + 理由をdashboardに残す |
| 後で | 家老へ `status: deferred` + `defer.autopull: eligible/hold` 反映を依頼 (eligible=idle自動pull対象) |
| B=決定 | 決定内容を memory(MCP) に記録 + 後続cmd要否を殿に確認 |
| C=是正 | **是正提案リスト**(cmd / 旧status→新status / 裏取り根拠) を家老へ渡し、家老が一括適用 |
| D=物理手番 | phase分け runsheet を生成して殿へ提示 (下記) |

**C層の渡し方** (将軍/足軽は直接編集しない):
```
status是正提案 (家老一元適用依頼):
- cmd_XXXX: in_progress → done  根拠: report QC PASS + commit XXXXX 実在
- cmd_YYYY: pending → deferred  根拠: 前提cmd_ZZZ未完で着手不可
```

**D層 runsheet の phase分け** — stack依存を判定して順序付ける:
```
## 殿 物理手番 runsheet ({日付})

### Phase 1 (独立・並行可)
1. [ ] cmd_XXX: backend を git push (WSL→origin)
2. [ ] cmd_YYY: 生成音声を実機聴取

### Phase 2 (Phase1依存)
3. [ ] cmd_ZZZ: Windows で npm install→UI確認 (Phase1のpush後)
```
依存無し項目は Phase 1 に並べ、前段成果に依存する項目を後続 Phase へ。memory `feedback_shogun_key_request_flow`(キー待ち集約) と整合。

最後に**実施サマリ**を出す: GO {n}件 dispatch / NG {n}件 / 後で {n}件 / C是正 {n}件 家老依頼 / D runsheet {n}手番。

---

## Dry-run 検証例 (2026-06-29 実データ)

本日の実 cmd で4ステップを通した検証 (捏造なし・`shogun_to_karo.yaml` 実値):

**Step 1 実態照合**: `/task-review` + YAML走査で open cmd 抽出。
- cmd_1111 (engine司令塔orchestrator): `in_progress`・設計完遂(plans/cmd_1111_*.md by gunshi2)・実装S1は殿レビュー後 → タグ=`設計完遂・殿レビュー待ち`
- cmd_1118 (engine gate 60問拡張): `in_progress`・設計完遂(plans/cmd_1118_gate_testset.md)・実装は殿レビュー後 → タグ=`設計完遂・殿レビュー待ち`
- cmd_1105b (翠プレゼンPoC): 殿決裁=案A済・gunshi2 QC PASS_WITH_OBS・**殿手番=push+TTS実走(翠RVC待ち)** → タグ=`殿物理手番待ち`
- status是正: dashboard完了だがYAML古いcmd群 → タグ=`bookkeeping不整合`

**Step 2 4層分類**:
- A層: cmd_1111, cmd_1118 (設計承認→実装GO待ち、共に要対応#9行列)
- D層: cmd_1105b (push の物理手番)
- C層: status是正対象cmd群

**Step 3 1個ずつ**:
- 【A-1】cmd_1111 → 「engine司令塔の実装S1をGOするか」要約提示 → 殿 GO/NG/後で
- 【A-2】cmd_1118 → 「gate 60問の実装(cmd_1109 skill統合)をGOするか」提示 → 殿判断
  (A-1判断後にA-2へ。一度に両方聞かない)

**Step 4 適用**:
- A=GO → 家老へ実装dispatch inbox_write
- C → status是正提案リストを家老一元適用へ
- D → cmd_1105b push を runsheet Phase 1 (独立) に記載

この一連が「本日殿が実演し『好き・スキル化したい』と評したフロー」の再現である。

## 補足

- **internal tool quality bar緩和** (memory `feedback_internal_tool_quality_bar`): 本スキルは動けばOK・PDCAで改善。完璧主義で止めない。
- **将軍/殿レビュー前提**: skill登録は原則承認 (memory `feedback_skill_registration_default_approve`) だが、本スキル自体の最終調整は将軍/殿が行う。
- **status直接編集の禁止**: Step 4 の status反映は必ず家老経由。将軍も足軽もYAMLを直接書かない (RACE-001回避)。
