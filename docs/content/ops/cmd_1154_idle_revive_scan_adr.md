# ADR: idle_revive_scan — 家老非依存の能動 idle-poll / auto-revive (cmd_1154)

- **status**: Accepted(実装 2026-07-01 Task A / 2026-07-02 Task B-D)
- **parent_cmd**: cmd_1154(家老 resume 信頼性 根本改修・whack-a-mole 廃)
- **owner**: gunshi2(system 改善)/ 実装 ashigaru1
- **関連 memory**: `feedback_heavy_generation_periodic_clear` / `feedback_watch_loop_always_on` /
  `feedback_lora_chain_stall_prevention` / `feedback_shogun_system_improvement_delegation` /
  `feedback_verify_before_assert`

---

## 1. Context(なぜ必要か)

重い生成 loop(企画 re-author 等)は殿留守中も自律で回り続ける想定だが、2026-07-01 の実データで
**1日に agent idle 固着 7〜8回 + 家老 context 肥大による機能不全 1回** を将軍が手動で凌いだ。

構造的な根:従来の「idle→revive」は **家老依存**だった。`instructions/karo.md` の Stall Watchdog が
**karo loop の中で走る**ため、家老自身が degrade/固着すると停止し、将軍が手動で埋める
(=whack-a-mole)。将軍の手が塞がれば殿がブロックされる(`feedback_shogun_hands_free`)。

## 2. Decision(何を選んだか)

**karo 非依存の独立 cron scan `scripts/idle_revive_scan.py` を主機構とする**。既存 `stall_watchdog_scan.py`
の scan/YAML/inbox_write パターンと `lib/agent_status.sh`(spinner 判定)を流用(車輪の再発明はしない)。

将軍レビュー 3分岐(設計 §7)の裁定 = 軍師推奨を採用:

| 分岐 | 採用 |
|------|------|
| (A) 独立script vs 家老組込 | **①cron 独立 scan**(stall_watchdog 兄弟)= karo 非依存で degrade 耐性・proven pattern 流用・最小侵襲 |
| (B) 家老 degrade 対策 | **③両方** = primary 自動 clear(reactive・scan)+ backstop 定期 self-clear(proactive・karo.md 規律) |
| (C) rate limit 値 | **agent≥5分 / karo≥20分 + 連続3回で escalation 停止** = CLAUDE.md「5分1回」整合・clear-loop 断ち切り |

### 誤 revive 防止 = 複合 AND 判定

`revive ⇔ (a) spinner無 AND (b) status∈{assigned,in_progress}且つ未完 AND (c) 出力file mtime 停止(>stall_min)`。
3 signal のいずれか 1 つでも「稼働」を示せば触らない(安全側)。**slow-gen(ash6 xhigh 事例=遅い漸進生成)は
(c) 出力file mtime が新鮮ゆえ revive しない** — これが誤 revive 0 の要。

### 家老 degrade 検知(Task B・実データ乖離ベース・憶測禁)

- (i) `dashboard.md` mtime が `karo-stale-min`(default 20分)超 stale
- (ii) 且つ active task(assigned/in_progress)が存在(=誰か稼働中なのに家老の記録が固まっている)
- (iii) 乖離 corroboration = task/report YAML の mtime が dashboard mtime より新しい(現場は進んだが家老が追随せず)

hit → karo へ `clear_command`(rate limit karo≥20分)→ SessionStart hook で復旧。
**dashboard prose の scrape はしない**(壊れやすい/憶測)——mtime + YAML status のみで判定する。
karo が連続 clear でも復帰せねば escalation を **shogun** へ上げて自動 revive を停止(clear-loop 断ち切り)。

### 過剰介入防止 = rate limit

`queue/state/clear_log.yaml`(agent→last_clear_ts / consecutive / last_task_id)で最終 clear 時刻を記録。
scan は発行前に間隔 check(間隔未満は skip・空振り静か)。連続 N 回で escalation 停止。

## 3. Non-destructive の担保

`/clear` は state を破壊しない:`session_start_hook.sh`(matcher=clear/compact)が persona/戦国口調/forbidden を
再注入し、CLAUDE.md Session Start が queue YAML(tasks/reports/inbox)から state を再構築する。
足軽は task YAML から、家老は dashboard を queue YAML から再構築。**state 損失ゼロ**。

## 4. Consequences

- **Pro**: 家老 degrade/固着に耐性(karo 非依存)。殿留守中も重い loop が自律継続 = 枠効率最大化。
  proven pattern 流用で最小侵襲。複合 AND + rate limit で誤 revive / clear-loop を抑制。
- **Con / 残リスク**:
  - cron 常駐は system 全体の挙動変更 → **smoke S1-S4(dry-run)客観確認 → gunshi2 QC PASS 後に活性化**
    (`scripts/idle_revive_scan.cron` は staged=未登録)。
  - 既存 karo Watchdog と二重発火の懸念 → karo Watchdog を補助降格(`instructions/karo.md`)+ rate limit で吸収。
  - stall_min 閾値は bloom 別調整余地(re-author 重 loop=15-20分 / 簡易=10分)。

## 5. 検証(smoke S1-S4・2026-07-02 実走・全期待一致)

| # | シナリオ | 期待 | 結果 |
|---|---------|------|------|
| S1 | idle固着(assigned+未完+spinner無+file停止) | revive 発行 | ✅ ACTION=revive |
| S2 | slow-gen(出力jsonl 漸進=mtime 新鮮) | revive しない(誤revive0) | ✅ 対象なし |
| S3 | 家老 stale(dashboard mtime 古)+乖離+active task | karo revive | ✅ ACTION=revive AGENT=karo |
| S4 | 同一 agent 連続 clear(前回2分前) | rate limit skip | ✅ ACTION=rate_limited |

補助検証:escalation_stop(連続3回≥max)分岐 = ✅ / 本番実データ dry-run = crash 無・誤検知 0(karo dashboard 新鮮ゆえ非発火)。

## 6. 活性化(QC PASS 後・家老 or 殿)

`scripts/idle_revive_scan.cron` のコメントに手順を記載。3分間隔・live 行は `--dry-run` を付けない。
```
crontab -l | grep idle_revive_scan_cmd1154   # 登録確認
tail -f logs/idle_revive_scan.log             # 初回発動確認
```
