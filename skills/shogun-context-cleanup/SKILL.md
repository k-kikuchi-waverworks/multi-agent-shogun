---
name: shogun-context-cleanup
description: |
  shogunシステムの肥大化(dashboard/inbox/plans/reports/tasks/memory/エージェントcontext)を
  診断→自動整理→/clear棚卸し→memory剪定案の4段階で掃除し「もっさり」を解消するスキル。
  5ヶ月運用の蓄積でrecall/動作品質が落ちた時に定期実行する。
  「掃除」「整理」「もっさり」「context cleanup」「肥大化」「システム重い」で起動。
  ★memory剪定は殿承認ゲート絶対(削除は殿承認後のみ)・誤削除厳禁・archive移動優先・backup必須★
  Do NOT use for: タスクのQC漏れ検出(quality-gate)・残タスク棚卸し(task-review)・
  エージェント稼働確認(shogun-agent-status)。本スキルは「掃除/整理」に特化。
---

# shogun-context-cleanup — システム肥大化の掃除

## Overview

5ヶ月運用で各層(dashboard/inbox/plans/reports/tasks/memory/エージェントcontext)が肥大化すると、
エージェント動作が「もっさり」し、将軍の tool call も不安定になる。肥大は recall/動作品質の根。
本スキルはそれを **診断 → 自動整理 → /clear棚卸し → memory剪定案** の4段階で定期的に断つ。

cmd_948(2026-06-21)で手動実施した掃除(dashboard 172→84KB / plans 375→72件 / inbox snapshot退避)
を再現可能な手順として恒久化したもの。

## When to Use

- 「掃除」「整理」「もっさり」「context cleanup」「肥大化」「システム重い」と言われた時
- dashboard が 100KB を超えた / plans が溜まった / inbox が長大化した時
- エージェントの応答が遅い・tool call が不安定になってきた時
- 大きな cmd 連鎖が一段落し、状態をリセットしたい時

## 既存スキルとの非重複(重要)

| スキル | 役割 | 本スキルとの違い |
|--------|------|------------------|
| `quality-gate` | 完了cmdのQC/テスト/レビュー漏れ検出 | 品質**監査**。掃除はしない |
| `task-review` | 残タスク・詰め残し・放置の棚卸し | タスク**洗い出し**。整理はしない |
| `shogun-agent-status` | エージェント稼働状態の一覧 | 稼働**観測**。context整理はしない |
| **shogun-context-cleanup** | 肥大層の**掃除・整理・archive・剪定案** | 本スキル = 物理的な軽量化に特化 |

→ 本スキルは「ファイル/contextを軽くする」ことに専念し、品質判定やタスク管理は上記に委ねる。

---

## フロー(4段階)

### ① 診断(計測・完全非破壊)

まず現状を READ-ONLY で計測する。専用スクリプトを使う:

```bash
bash scripts/context_cleanup_diagnose.sh
```

出力される肥大層(優先度付き):
- **dashboard.md**: サイズ(KB)・行数 — 目標 <100KB
- **queue/inbox/*.yaml**: 各行数・read:false(未処理)/read:true(処理済)内訳
- **plans/**: 直下件数・容量・archive済件数
- **queue/reports, queue/tasks**: 件数・status内訳(completed/assigned/blocked)
- **memory**: ファイル数・MEMORY.md index行数
- **tmux pane context token**: best-effort(>100k は段階③候補)

このスクリプトは **一切ファイルを変更しない**。整理は②以降で人(将軍/家老)の判断で行う。

### ② 自動整理(archive移動優先・active必残)

肥大層を archive 退避中心で整理する。**物理削除より archive 移動を常に優先**。

- **dashboard** (`instructions/karo.md` §クローズ時archive運用ルール準拠):
  - 退避対象 = cmd完遂 + QC PASS + 殿手番なし の古い見出し
  - 退避先 = `archive/dashboard_archive_{YYYYMMDD}.md`(なければ新設)
  - **active必残(絶対退避禁)** = 進行中 / 殿手番待ち(再起動・push・verify) / 直近殿確認系 / 🚨incident
  - dashboard 先頭に `> 📦 過去戦果は archive/dashboard_archive_{date}.md 参照` を追記
  - 目標 <100KB
- **plans**: 完遂cmd(QC PASS済)の plan を `plans/archive/` へ移動。in-flight(現行cmd)は保持
- **inbox**: read:true の古い entry を保守的に剪定(最新N件は保持)。
  - 剪定前に必ず snapshot を退避(例: `cp queue/inbox/{agent}.yaml queue/inbox/_snapshot_{agent}_{date}.yaml` 等の backup)
  - read:false(未処理)は絶対消すな。karo/active エージェント・本日分は保持
- **reports/tasks**: 完遂分を `queue/reports/archive/` `queue/tasks/archive/` へ。active/現行スロットは保持

各操作後に件数/サイズ diff を確認し、退避一覧を明記する。

### ③ エージェント /clear 棚卸し(idle確認必須)

context が肥大した pane を順次リセットする(各エージェントは Session Start手順でYAMLから復帰する設計ゆえ安全)。

- 段階①の pane token を見て **>100k** の肥大 pane を対象化
- **idle確認必須**: 進行中タスク保持者・緊急cmd関与者は**除外**(作業を壊さない)
- リセットは inbox の `type: clear_command` 経由で行う(`bash scripts/inbox_write.sh {agent} "..." clear_command karo`)
  — エージェントへ tmux send-keys を直接打たない(基盤層が配送)
- 1人ずつ、idle を確認しながら順次実行

### ④ memory 剪定(★殿承認ゲート絶対★)

メモリは最も慎重に扱う。**自動削除は禁止。候補提示のみ。削除は殿承認後にのみ実行**
([[feedback_rag_merge_flow]] = memoryは殿レビュー→承認後マージ/削除)。

手順:
1. 剪定**候補**を一覧化(削除はしない):
   - 古い session スナップショット(完遂・superseded。例: `session_*_state.md`)
   - orphan(参照されていない) / 全 observation が superseded された entity
   - ※休眠案件(例: 将来再開予定)は「削除」でなく「休眠保持」に分類 = retain
2. 候補を殿に提示(dashboard 🚨要対応 or 報告)
3. **殿承認後にのみ**:
   - `tar` で memory ディレクトリを backup
   - 対象ファイル削除
   - `MEMORY.md` の該当 index 行を削除
   - broken link 修正(`grep -rl "[[消したname]]" memory/` で参照元検出 → Edit)

---

## 規律(全段階共通)

1. **誤削除厳禁** — 迷えば残す(誤退避 > 残存過多 のリスク)
2. **archive移動を物理削除より優先** — 消す前にまず退避
3. **backup必須** — inbox剪定前 snapshot / memory剪定前 tar
4. **memory剪定は殿承認ゲート絶対** — 案提示のみ、削除自動化禁止
5. **active必残** — 進行中 / 殿手番待ち / incident は全層で保護
6. **各操作後に到達確認** — diff / 件数 / サイズで結果検証(捏造禁・[[feedback_verify_before_assert]])
7. **push は殿手番** — 整理結果のコミットは作るが push しない

## 成果物

- 診断レポート(段階①の計測値)
- 整理後の before/after 数値(dashboard KB / plans 件数 / inbox 行数 等)を dashboard に要約
- memory剪定は「候補一覧」を殿提示(削除実行は承認後)
