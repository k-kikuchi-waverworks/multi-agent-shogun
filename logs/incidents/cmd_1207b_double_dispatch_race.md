# Incident: cmd_1207b 二重dispatch RACE-001（家老の過失）

- **日時**: 2026-07-04 15:49〜16:02
- **重大度**: 中（データ破損なし・agent自己防御で回避・軽微なテーマ重複リスクのみ）
- **起票**: karo（自己申告）
- **関係**: ashigaru1, ashigaru4, karo, idle_revive_scan(cmd_1154)

## 何が起きたか

cmd_1207b（燈kikaku観戦Batch）が **ashigaru1 と ashigaru4 に二重アサイン**され、両者が同一正本
`ai-automate-engine/data/kikaku_stock/akari_kikaku.jsonl` へ並行 append した（RACE-001違反）。

## 根本原因（家老の誤判断）

1. **15:15** cmd_1207b を ash1 へ task_assigned で dispatch。
2. **15:48** idle_revive_scan が「ashigaru1 を連続3回clearしても復帰せず・手動確認要」を escalation。
3. **家老の誤断**: これを「ash1死亡＝成果物未write」と解釈。確認として (a) ash1 pane（idle ❯表示）(b) ash1 report YAML（旧cmd_1221内容=stale）を見た。**さらに deliverable の実在確認を `find /home/k-kikuchi/aituber-project -iname "akari_kikaku*"` で行い「NOT FOUND」→ 未writeと断定**。
4. **★誤りの核心★**: 燈kikaku正本は **aituber-project ではなく ai-automate-engine repo** にある（`data/kikaku_stock/akari_kikaku.jsonl`）。家老の find は**間違ったrepoを探索**したため false「見つからない」を返した。実際には ash1 は clear-loop から**復帰して 301-310 を authoring 中**だった。
5. 家老は「ash1は成果物ゼロ」と誤断し、cmd_1207b を **ash4 へ再dispatch** → 二重アサイン成立。

## 検知と回復（agentの的確な防御）

- **ash4**: 着任時 301-308 既存を確認。309(舞台観劇)を append 直後、ash1 の遅延write 309(チャント研究)/310(応援グッズ)と衝突検知 → **自らのentryを 311-314 へ renumber** して ID衝突を回避。
- **ash1**: ash4 の並行append(plan-311)を検知 → 10件(301-310)で**自主停止**し RACE警報を家老へ報告。
- **結果**: 正本は 314行・**dup_id 0・parse_fail 0**（構造無傷）。301-310=ash1(10件)/311-314=ash4(4件)=計14件（10-15枠内）。

## 影響

- データ破損なし（agent自己防御）。データ損失なし。
- 残リスク: ash1分とash4分の**テーマ内容重複**（両者独立に観戦企画を執筆）→ gunshi2 QC で dedup 判定へ回付（301-314）。

## 教訓（再発防止）

1. **idle_revive_scan の「3回clear→復帰せず」escalation ≠ agent死亡**。scanのclear試行が失敗した意味であり、agentはclear間に復帰して稼働継続している場合がある。
2. **false-clear された task を別agentへ再dispatchする前に、必ず deliverable file の最近の書込を検証せよ。しかも正しいrepoで**。本件は正本が ai-automate-engine にあるのに aituber-project を探索した = 検証手段の誤り。
3. task YAML の `repo_path` や deliverable記載の正本locationを見て、**正しいpathで mtime/内容を確認**すること。pane表示(idle)+report YAML(stale)だけでは「稼働中で未report」と「死亡」を区別できない。
4. RACE-001防御はagent側で機能した（並行write自己検知+renumber/停止）が、**家老が二重アサインを作らぬのが第一義**。
5. 「手動確認要」の手動確認には、**deliverable実体の確認を必ず含める**。

## 関連

- [[feedback_redispatch_verify_deliverable]]（memory化）
- idle_revive_scan false-clear の infra恒久fix（dashboard 🚨・cmd_1154系）= read-heavy authoringのmtime停滞にgrace period要
- RACE-001（CLAUDE.md / karo.md）
