# cmd_639 incident: 07de510 軍師誤検知事案 教訓記録

| 項目 | 内容 |
|------|------|
| incident_id | cmd_639_07de510_misdetection |
| commit_hash | `07de510` |
| original_cmd | cmd_621 P5 step_2 |
| affected_agent | gunshi (spot QC fabrication 判定) / ashigaru6 (不要 redo 発生) |
| recorded_at | 2026-05-10 |
| recorded_by | ashigaru7 (cmd_639 実装) |
| protocol_origin | `instructions/gunshi.md § Commit Hash Verification Protocol` + `instructions/karo.md § Commit Hash Pre-Dashboard Verification` |

---

## §1 概要

2026-05-09 に cmd_621 P5 step_2 で ashigaru6 が報告した commit `07de510` を、軍師 spot QC が「3 repo 全証拠で不在」と判定し fabrication 認定した。これを受けて ashigaru6 は redo を実施し、新 commit `c18069d` を作成。

しかし 2026-05-10 に殿が実機 `git rebase` 検証を行った結果、**`07de510` は origin/main 上に実在する真の commit と判明**。`git rebase --abort` + `git reset --hard origin/main` で integrity 復旧 (c18069d は破棄、07de510 が main 真値)。

本 incident は **軍師 spot QC の prerequisite 不足 (3 repo 全 git fetch 未実行) による偽陽性誤検知**であり、双方向誤報防止規律 (cmd_639) の制度的担保元事案。memory `feedback_no_misleading_information` (2026-05-08 殿明示) に直結。

---

## §2 timeline

| 時刻 | 主体 | 出来事 | evidence |
|------|------|--------|----------|
| 2026-05-09 08:34 | ashigaru6 | cmd_621 P5 step_2 完遂報告、commit `07de510` (Modal config v1→v2 切替 3 修正点) | `queue/reports/ashigaru6_report.yaml` (status: completed) |
| 2026-05-09 08:37 | karo | 軍師 cmd_621 P5 step_2 spot QC dispatch | `queue/inbox/gunshi.yaml` `msg_20260509_083733` |
| 2026-05-09 ~08:44 | gunshi | spot QC FAIL (fabrication 判定): 「3 repo `git object` + `git log` + working tree 全証拠で commit `07de510` 不在、Modal config 修正実装ゼロ」 | ashigaru6 redo report `previous_report_invalid` 欄 |
| 2026-05-09 08:51 | ashigaru6 | redo 完遂、新 commit `c18069d` (full `c18069d9eedcdecefc9439eb6aff2c17ae7d8874`) で 4 修正点 commit、push 殿手動 | `queue/reports/ashigaru6_report.yaml` (status: completed、redo_of) |
| 2026-05-10 10:39 | 殿 | 実機 `git rebase` 検証で **`07de510` は実在 commit と判明** (origin/main 既 push state)、`git rebase --abort` + `git reset --hard origin/main` で integrity 復旧 (`c18069d` 破棄、`07de510` が main 真値) | `msg_103925` (殿明示) |
| 2026-05-10 10:39 | 殿 | cmd_639 (高優先) / cmd_640 (中優先) 起票委任 | `queue/shogun_to_karo.yaml` line 12071+ |
| 2026-05-10 11:02 | gunshi | cmd_639 plan 起草完遂 (`plans/cmd_639_ash_report_verification.md` ~600 行) | `msg_110256` |
| 2026-05-10 ~11:05 | karo | cmd_639 ash7 dispatch (Lord-K skip) | `queue/inbox/ashigaru7.yaml` `msg_20260510_110456` |
| 2026-05-10 (本 incident 起票) | ashigaru7 | cmd_639 ash 実装で本 incident report 起票 + verification 規律 doc 化 + retroactive_commit_verify.sh 起源 | `logs/incidents/cmd_639_07de510_misdetection.md` (本 file) |

---

## §3 機序 (なぜ軍師判定が誤検知になったか)

1. ashigaru6 は commit `07de510` を **WSL canonical path** (`/home/k-kikuchi/aituber-project`) で作成し、即 origin/main へ push (殿実行 path、memory `project_wsl_app_canonical` 整合)
2. 軍師は将軍環境 (`/mnt/c/Users/k-kikuchi/development/aituber-project` Windows path) で `git log` / `git cat-file` を実行 (★`git fetch` 未実行★)
3. 将軍環境のローカル refs は push 前 state ゆえ `07de510` オブジェクトが見えず、「3 repo で不在」と判定 (origin/main は別 repo 物理状態)
4. ★抜け落ちた prerequisite★: `git fetch origin` 実行 → origin/main の最新 ref 取得 → `git cat-file -t 07de510` で `commit` 確認

---

## §4 教訓

| # | 教訓 | 規律化先 |
|---|------|----------|
| 1 | 「3 repo 全証拠で不在」と断言する前に **3 repo 全 fetch + `git cat-file -t` 確認** が prerequisite | `instructions/gunshi.md § Commit Hash Verification Protocol` |
| 2 | ash 報告 commit hash は **`git show <hash>` 実証出力** を report に同梱必須 | `instructions/gunshi.md § Commit Hash Verification Protocol` (ash 側既往慣行を再強化) |
| 3 | 家老 `dashboard.md` 反映前にも `git rev-parse` 検証 fail-safe | `instructions/karo.md § Commit Hash Pre-Dashboard Verification` |
| 4 | 殿環境差考慮 (WSL canonical / Windows mount / submodule など) で repo path 整合確認 | 同上 |
| 5 | fetch 前 fail / fetch 後 OK パターンは **必ず incident report 化** (`logs/incidents/`) | `instructions/gunshi.md § Commit Hash Verification Protocol` 失敗時動作 |

---

## §5 再発防止規律 (cmd_639 制度化)

- ★軍師★: ash 報告 commit hash 検証は判定前に必ず 3 repo 全 `git fetch origin` + `git cat-file -t <hash>` + `git show <hash> --stat` の 3 段確認 (`instructions/gunshi.md` 反映済)
- ★家老★: ash 報告の commit hash を `dashboard.md` 反映する前に必ず `git rev-parse <hash>` で実在確認 (`instructions/karo.md` 反映済)
- ★retroactive 監査★: 過去 cmd 累積 commit hash を 3 分類 (truth / misdetection_revealed / fabrication_candidate) で audit する `scripts/retroactive_commit_verify.sh` を新規化 (cmd_639 ash7 実装で起源)
- ★ash6 retrospective dialog★: 不要 redo を発生させた点について 1on1 dialog で educational 共有 (本 cmd 完遂後、家老主導、record `logs/dialogs/cmd_639_ash6_retrospective_<YYYYMMDD>.md`)

---

## §6 関連 cmd / 関連 doc

- cmd_621 P5 step_2 (本事案発生元、ashigaru6 redo 起点)
- cmd_639 (双方向誤報防止規律、本 incident 教訓化、ash7 実装)
- cmd_640 (template review、cmd_639 完遂後 sequential)
- `plans/cmd_639_ash_report_verification.md` (軍師 plan 全文)
- `instructions/gunshi.md § Commit Hash Verification Protocol`
- `instructions/karo.md § Commit Hash Pre-Dashboard Verification`
- `scripts/retroactive_commit_verify.sh`
- `logs/dialogs/cmd_639_ash6_retrospective_TEMPLATE.md`
- memory: `feedback_no_misleading_information` (2026-05-08 殿明示)

---

## §7 影響

- ashigaru6 不要 redo 発生 (~17 min cmd_621 P5 step_2 redo 工数 + redo report 書き起こし負荷)
- `c18069d` 破棄、`reset --hard origin/main` で main integrity 復旧 (殿手番 1 件発生)
- ashigaru6 心理的負荷 (fabrication 認定された側、retrospective dialog で educational 解消予定)
- 本 incident を起源に cmd_639 双方向誤報防止規律確立 (memory `feedback_no_misleading_information` 制度的担保達成)
- `07de510` 自体は **真値 commit**、cmd_621 P5 step_2 の Modal config v1→v2 切替 3 修正点は origin/main 上で正常反映済
