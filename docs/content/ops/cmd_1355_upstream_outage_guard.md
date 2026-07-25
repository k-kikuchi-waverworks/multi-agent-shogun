# 上流障害 guard + 枠復帰の再開通知 (cmd_1355)

**消す前に読め (Chesterton's Fence)**: この仕組みは 2026-07-26 未明に**全軍が3時間死んだ**
実害を機械で塞ぐために在る。死因は「枠切れ」ではない — **枠切れを idle 固着と見誤り、
治らぬ傷に /clear を撃ち続けた検知層**と、**枠が戻った後に誰も起こさなかった**空白である。
番人が誤って味方を斬り、しかも夜が明けるまで誰もそれに気付けなかった。

## 実害の時系列 (2026-07-26 未明・一次資料から再構成)

| 時刻 | 事実 | 根拠 |
|---|---|---|
| 〜01:5x | 殿の session limit 到来。足軽一号/二号/六号らの pane に限界文言 | pane scrollback 実採取 (下記) |
| 01:55 | 足軽三号が中間報を最後に沈黙 | queue/reports |
| 01:57 | **家老自身が auto-recovery /clear を被弾** — 以後 04:30 まで無音 | karo inbox / clear_log |
| 〜02:2x | 軍師一号/二号へ**各3回 /clear 連射** → 3連続失敗で escalation 停止 | logs/idle_revive_scan.log |
| 02:24-04:27 | 家老 inbox へ escalation 警報 **10通** (30分 cooldown ごと・誰も読めぬまま) | queue/inbox/karo.yaml |
| 04:30 | 枠回復。**だが誰も全軍を起こさず** — 停止時間の大半はこの空白 | 実測 |

**検知層は quorum gate (cmd_1339) を持っていたのに素通りした**理由は2つ:
1. 実文言 `session limit` が `UPSTREAM_FAILURE_PATTERNS` に無かった (在ったのは `usage limit`)。
2. eligible な agent が少数 (軍師2+家老) で quorum (≥3体かつ≥75%) が不成立 = 個別経路に落ち、
   個別経路の上流障害 gate も 1. の理由で素通りした。

さらに悪いことに、**誤 /clear は pane の限界文言 (証拠) ごと消す**。軍師の pane には
清められた prompt しか残っておらず、後続 scan には「ただの idle」に見えた。
→ **pane は揮発証拠である。抑止の瞬間に台帳へ永続化せねばならぬ** (原理(ii) の台帳版)。

## 実文言 (推測でなく capture-pane 採取・byte 凍結)

ashigaru6 pane (%3) scrollback より 2026-07-26 04:4x 採取。正本 =
`tests/fixtures/upstream_session_limit_pane.txt` (tmux から直接 redirect・手打ち転写なし):

```
  ⎿  You've hit your session limit · resets 4:30am
     (Asia/Tokyo)
     /usage-credits to finish what you’re working
     on.
```

- `·` = C2 B7 (U+00B7) / `’` = E2 80 99 (U+2019) / `⎿` 直後に NBSP (C2 A0)。
- **pane 幅 52 で折返すため `(Asia/Tokyo)` は別物理行** — pattern は折返しを跨がぬ短句のみ:
  追加したのは `session limit` と `/usage-credits` の2つだけ。
- 境界は従来どおり「**/clear では直らぬ account/枠/認証系に限る**」(一時的 5xx は含めない)。

## 何が加わったか (scripts/idle_revive_scan.py)

1. **pattern 追加** — 上記2句 (実文言由来のみ)。
2. **escalation にも上流障害 gate** — 枠切れ agent への「復帰せず」警報は誤診であり、
   今夜の 10通 spam の型。検知したら台帳へ記録し警報は出さない。
3. **上流障害 台帳** `queue/state/upstream_outage.yaml` — 抑止した agent / 検知時刻 /
   pattern / task_id / 検知文言 excerpt / resets ETA を episode 単位で記録。
   個別 gate・escalation gate・blackout (quorum) の3経路すべてから記録される
   (blackout 警報が throttle 中でも記録は落とさない)。
4. **episode 初回の検知警報1通** — 家老へ「抑止した。再開通知を別途上げる」。
   blackout 警報が同 cycle に出た時は相乗り (2通にしない)。30分 throttle 併設。
5. **★枠復帰の再開通知★ (本任の主目的)** — 解除条件成立で家老へ「再開せよ」を
   **1 episode に 1通だけ**。配達層 (inbox_write → watcher nudge/escalation) が再送を
   担うゆえ 1通で足る — **家老自身が枠切れ中でも、枠回復後の nudge がこの1通で家老を起こす**。
6. **家老 clear も同じ guard** — 家老 degrade clear は個別経路と同じ発行直前 gate を通る
   (T-QRM-011 で両側実証)。01:57 の家老被弾は 1. の pattern 欠落が原因であり、経路自体は
   guard 下にあった。

## 解除条件 (優先順) と★脆さの正直明示★

| 条件 | 内容 | 位置づけ |
|---|---|---|
| R1 | pane 文言から parse した resets ETA + 3分 grace を経過 | **主判定 (実効)** |
| R2 | ETA を読めなんだ場合、初回検知から 60分で点検通知 | fallback |
| R3 | 全対象 pane から限界文言が消え、かつ idle の agent が居る | 補助 |

- **R3 が補助である理由 (家老の見立てを実測で覆した点)**: 家老は「pane から限界文言が
  消え、かつ idle」を主判定に置く見立てであったが、**banner は枠回復後も pane に残り続ける**
  (04:4x 時点で ashigaru6 pane に 4:30am の banner が残存するのを実測)。agent は死んだまま
  何も出力しないので、文言は自然には消えない。自然に成立しない条件を主判定には置けぬ。
  R3 が効くのは /clear や scroll で文言が流れた場合のみ。
- **R1 の脆さ (隠さず列挙)**:
  - `resets 4:30am` は 12h 表記・分省略 (`resets 1am`) を parse するが、**表示 TZ = host TZ
    (Asia/Tokyo) の仮定**を置いている。TZ 括弧は折返しで別行に落ちるため検証に使えない。
  - 「検知時点から見た次の到来時刻」と解釈する。**検知が reset 後にずれ込んだ stale banner
    は翌日へ繰上がる誤読**になる (最大24h の遅延)。下限保証として episode は 24h で expire。
  - 文言の書式が CLI 更新で変われば parse は静かに失敗する — その時は **R2 fallback が
    60分で必ず点検通知を上げる** (parse 失敗で誰も起こさぬ事態にはならない。この契約は
    MUT-1355-002 が毎朝守る)。
- 通知の spam 抑止: episode 1通が主 + 30分 throttle が保険 (10通 spam の再発禁)。

## 試験 (すべて「壊せば落ちるか」で検めた)

- `python3 scripts/idle_revive_scan.py --selftest-upstream` — U1-U5 (fixture 検知/良性非検知/
  ETA parse/解除判定両側)。tmux/queue 非接触ゆえ gate-2 台帳から scratch 実行できる。
- `config/mutation_registry.yaml` MUT-1355-001 (pattern 削除→U1b 名指し赤) /
  MUT-1355-002 (R2 fallback 折り→U4d 名指し赤)。毎朝 06:30 gate_nightly が再走。
- `tests/unit/test_idle_revive_quorum.bats` T-QRM-010〜013 — 実文言で clear 0本+警報1通、
  家老 guard 両側、resume 1通+全員回復 close、pattern 外しで**今夜の誤 clear が再現**する
  scan 級両側実測。
- 検分自身の沈黙を1件踏んで塞いだ: fixture には pattern が2つ共存するため、全文一括の
  検分では「片方外し」の変異が空振りする — 行単位の個別検分 (U1b/U1c) へ強化した。

## 運用

- 本 guard は既存 cron (`idle_revive_scan_cmd1154`・3分毎) に相乗り — 人が思い出して回す物は無い。
- 台帳の検分: `cat queue/state/upstream_outage.yaml`。episode を手で畳みたい時は同 file を
  削除すればよい (次の検知で新 episode が立つ)。throttle は `queue/state/upstream_alert_throttle`。
- 再開通知を受けた家老の手番: 台帳の agent 一覧へ inbox nudge / task 再確認を出す
  (agent は枠が戻っても**自分では再開しない**)。
