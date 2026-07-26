# cmd_1359 — 帳簿漏れの番人へ「呼ぶ者」を配線する

> 番人は、書いただけでは番をせぬ。

## 1. 病 — 目は開いておったが、呼ぶ者が居らなんだ

`scripts/stall_watchdog_scan.py` は **2026-04-22 に設置**されて以来、
**3ヶ月にわたり一度も発報しておらぬ**。軍師二号の検分で判明した内訳:

- cron に無し
- `watcher_supervisor` が回す7本に不在
- 常駐 process 0
- `logs/` に log file すら無い (= 一度も定期実行されておらぬ物証)
- **唯一の呼び口は「家老が手で回す時」だけ**

⇒ **家老が degrade すれば番人も一緒に沈む** = cmd_1154 が掲げた「karo 非依存」と背反。

**そして最も質が悪いのは、これが3ヶ月 誰にも気付かれなかったこと**。
**alert の不在は、無音と見分けがつかぬ**。鳴らぬ番人は、居らぬ番人と同じである。

## 2. 配線

`crontab` へ据えた (兄弟の番人 `idle_revive_scan` `gate_nightly` と同じ経路 = karo 非依存)。

```
*/15 * * * * /bin/bash /mnt/c/tools/multi-agent-shogun/scripts/stall_watchdog_scan.sh \
  --threshold-min 30 >> /mnt/c/tools/multi-agent-shogun/logs/stall_watchdog_scan.log 2>&1 \
  # stall_watchdog_cmd1359
```

## 3. 配線と同時に要った裁定 — task_id の再利用

軍師二号の警告: **配線した途端、真の漏れでないのに鳴り続ける**。
的は **家老が同じ task_id へ新しい手番を載せる癖**。

### 採らなかった道 — 運用則で人を縛る

`task_id` を毎回変えよ、と家老に課す道は採らぬ。
cmd_1356 で注記慣行を allowlist で吸収した時と同じ考えで、
**「癖を直せ」でなく「癖が在っても読める」側で吸収する**。

### 採った道 — `updated_at` で見分ける

| task 側の刻 | 判定 |
|---|---|
| `updated_at` > report 刻 | **再dispatch** = 新しい手番が走っておる ⇒ 鳴らさぬ |
| `updated_at` < report 刻 | **真の帳簿漏れ** ⇒ 鳴る |
| `updated_at` 不在 | **見分けられぬ** ⇒ **鳴らす側へ倒す** (握り潰さぬ) |

不在時の alert には「見分けられなんだ／`updated_at` を書けば以後鳴らぬ」と明記する。
**人を規則で縛らず、機械が読める形を書く方が得になる向きへ寄せる**。

> 実測: 現行 task YAML 12件中 `updated_at` を持つのは 8件。4件は判定不能側に落ちる。

### 意図して捨てた道 — file mtime を代理に使う

初版は `updated_at` 不在時に **file mtime** で代用した。
**既存 test 3本が赤くなって露見した** — `task` file に触れさえすれば、
genuine な帳簿漏れが黙って消える。

漏れとは「帳簿が**更新されておらぬ**」ことであり、
mtime は **更新の意思**ではなく **触れた事実** しか映さぬ (整形・別 field の編集・`cp` でも動く)。

⇒ **これは代理変数で生死を判ずる型であり、家老が 23:39 に dashboard mtime で
誤って「死」と判定され `/clear` された事故と同じ形である**。
本 cmd は沈黙を潰す任ゆえ、**沈黙を生む代理変数を新たに据えるのは本末転倒**。

## 4. 鳴りすぎで死なぬための番 (cooldown)

**常に赤い検知は無視されて死ぬ** — 15分ごとに同じ漏れを鳴らせば、家老は本 alert を読まなくなる。
それは沈黙と同じ結末である。

同一 `(agent, task_id)` は既定 **6時間** 再警報せぬ (`queue/state/stall_watchdog_alerted.yaml`)。
別の `task_id` は巻き込まれず即座に鳴る。state が壊れておれば **鳴る側へ倒れる** (fail-LOUD)。

**そして cooldown は諸刃である** — 倒れると「一度鳴った漏れが二度と鳴らぬ」へ変わる。
ゆえに `MUT-1359-003` が毎朝これを見張る。

## 5. 黙った事は、黙って黙らぬ

抑制を入れると **「効きすぎて全部握り潰しておる」と「本当に漏れが無い」が log 上で同じ顔になる**。
ゆえに **鳴らさなかった理由と件数を必ず印字する**:

```
[stall_watchdog] 再dispatchと判定し鳴らさず: AGENT=… TASK_ID=… 根拠=updated_at
[stall_watchdog] cooldown 中ゆえ再警報せず: … (cooldown=360分)
[stall_watchdog] 帳簿漏れ hit なし。assigned=2 再dispatch除外=0
```

これは `eligible=N` / `assigned=N` の分母印字と同じ考え方の、**抑制側の顔**である。

> なお **hit 行の署名は `ELAPSED_MIN=`** である。除外 log 行にも `AGENT=` は載るゆえ、
> `AGENT=` で test を書くと **握り潰されても緑になる**。
> 実際に `MUT-1359-001` がこの穴を暴いた = **台帳が、拙者の空虚な test を捕まえた**。

## 6. 配線そのものを毎朝見張る

**配線は repo の外 (crontab) に在る**。誰かが `crontab` を書き直せば、
**3ヶ月 発報0件の状態へ静かに戻る** — しかも誰も気付けぬ。

ゆえに `gate_nightly.sh` (毎朝 06:30) が **crontab を実際に読んで呼ぶ口の実在を確かめる**。
不在なら家老 inbox へ警告し、終了行に `配線=MISSING` を出す。
`crontab` 自体が見えぬ時は **UNDETERMINED (緑にせぬ)**。

**「番人を作る」だけでなく「番人が呼ばれておることを毎朝確かめる」までが本 cmd の任である。**

## 7. 検証

```bash
bats tests/unit/test_stall_watchdog_redispatch.bats   # 12件 (RDP/CD/WIR)
bash scripts/stall_watchdog_scan.sh --dry-run
```

既存 `test_stall_watchdog_scan.bats` + `..._status_normalize.bats` と併せて **29件 全緑**。
台帳 `MUT-1359-001`〜`004` を runner 実走で **4/4 PASS** (名指しの赤まで実測)。

> `T-WIR-*` は **`gate_nightly.sh` から当の行を機械抽出して**検める。
> 手写しの写しを検めても意味が無い (fixture が実体と乖離する罠)。
