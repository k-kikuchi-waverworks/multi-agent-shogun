# cmd_1418 — pane で CLI が現に動いているかを見る

作成: 2026-07-27 (足軽一号) / 起票: 家老 18:05・将軍が 12:25 に実測した穴

## 何が起きたか

足軽五号の claude が落ち、pane が素の bash に戻った。そこへ nudge が送られ、
bash がそれをコマンドとして食った (`command not found` が 9 回。`/clear` も同じ)。
配達は届いていたが、受け手が居なかった。

12:26 の点呼でも五号は「claude 稼働中」と出ていた。計器が緑を返していた。

実害の範囲: 未読は失われていない。ただし五号は 12:08 の指示を一度も読まず、約 17 分を失った。

**落ちた原因は判っていない。** 将軍も掴んでいない。本稿は原因を扱わない。

## 穴の中身

pane で CLI が生きているかを見る口が一つも無かった。既存の計器は二つとも別の物を見ている。

| 計器 | 何を見るか | 何を見ないか |
|---|---|---|
| `agent_is_busy_check` (`lib/agent_status.sh`) | pane に描かれた文字 | プロセスが居るか |
| pane metadata `@agent_cli` / settings.yaml | 何を起動する「はず」か | 現に起動しているか |

素の bash に戻った pane は文字が静かなので、文字を見る計器は「待機中」を返す。
metadata は札なので、落ちても書き換わらない。二つを重ねても実体には届かない。

## 置いた口

`lib/pane_cli_liveness.sh` — tmux の `pane_pid` から子プロセスを辿り、
各プロセスの argv (`/proc/<pid>/cmdline`) を読んで CLI が居るかを判ずる。
`pane_pid` 自身も候補に含める (CLI を pane の第一プロセスとして起動した形に備える)。

### 判定

| 判定 | ラベル | rc | 意味 |
|---|---|---|---|
| `alive` | 生存 | 0 | 期待した CLI のプロセスが現に居る |
| `dead` | 落ち | 1 | CLI が一つも居ない (pane は shell だけ) ← 本件 |
| `no_pane` | 不在 | 2 | pane が無い |
| `mismatch` | 別CLI | 3 | CLI は居るが札と違う |
| `unknown` | 不明 | 4 | 見られなかった (`/proc` が読めぬ等) |

### 使い方

```bash
bash scripts/pane_cli_liveness.sh                       # 全エージェント
bash scripts/pane_cli_liveness.sh --quiet               # 生存でない pane だけ
bash scripts/pane_cli_liveness.sh --pane multiagent:agents.5 --expect claude
```

`scripts/agent_status.sh` にも「実体」欄として載せた。既存の欄は変えていない。

```
Agent      CLI     Pane      実体    Task ID
ashigaru5  claude  待機中    落ち    subtask_xxxx     ← 札は緑・実体は落ちている
```

CLI 欄 (札) が `claude` のまま実体欄が「落ち」になる形が、本件で見えなかった状態である。

### 判定は読むだけで行う

プロセスへ signal を送らない。pane を殺さない。

## 途中で踏んだ穴 — `display-message` は宛先が無いと現在の pane へ落ちる

初版は pane の存在確認に `tmux display-message -t <pane> -p '#{pane_pid}'` を使った。
無い pane を指しても **rc=0 で現在の pane の pid が返る**。実測で確かめた。

```
$ tmux display-message -t multiagent:agents.99 -p '#{pane_pid}'
1405        # 存在しない pane なのに rc=0
$ tmux list-panes -t multiagent:agents.99 -F '#{pane_id}'
can't find pane: 99     # rc=1
```

存在確認は `list-panes` で行う形に直した。試験 T-PCL-007 がこの退行を止める。

なお `lib/agent_status.sh` の `agent_is_busy_check` も同じ形で pane の存在を見ている
(`display-message -p '#{pane_id}'`)。結果として、無い pane が「待機中」と出る
(`agent_status.sh` の gunshi_a / gunshi_b で現に起きている)。
**これは本稿では直していない。** busy 判定の側の持ち物であり、既存表示を変えるため。

## `command not found` をどこで拾えるか

`scripts/inbox_watcher.sh` の `send_wakeup` (978 行) が **既に撃った直後の pane を掴んでいる** —
1054 行あたりで送信確認のため `capture-pane … | tail -5` を読み、nudge の文字が残っていれば
再送する。ここで `command not found` も一緒に見れば拾える。**本 cmd では実装していない。**

補足 (実装する者への申し送り): 本件で見逃したのはこの確認そのものである。
bash は `inbox3` を食って `bash: inbox3: command not found` に置き換えるので、
nudge の文字は pane に残らない。既存の確認は「残っていない = 送信成功」と読む。
**食われた形が、届いた形と同じ顔で通っていた。**

## 試験

```bash
bats tests/unit/test_pane_cli_liveness.bats            # 12 本
bash tests/mutation_cmd1418_pane_cli_liveness.sh       # 変異 6 本
```

試験は使い捨ての tmux セッションを建てて畳む。稼働中の multiagent には触れない。
CLI の代わりに `exec -a claude /bin/sleep 300` で argv[0] を偽装したプロセスを使うので、
本物の claude を起動しない。

変異テストは判定を二段で出す。①壊した後の md5 が動いたか ②狙った試験が現に落ちたか。
負の対照を 1 本 置いてある (註釈を 1 行 足すだけの変異 → md5 は動くが全緑のまま)。
「md5 が動いた」は当たりの必要条件であって十分条件ではないため。

| 変異 | 壊す所 | 落ちる試験 |
|---|---|---|
| MUT-A | pane の存在確認を外す | T-PCL-007 |
| MUT-B | 常に alive を返す | T-PCL-001 |
| MUT-C | 木を辿らず pane_pid だけ見る | T-PCL-003 / 004 |
| MUT-D | node 噛ませの分岐を外す | T-PCL-008 |
| MUT-E | mismatch を dead へ倒す | T-PCL-005 |
| NC | 註釈を 1 行 足す | (落ちない = 正しい) |

## 保守で気をつけること

`pane_cli_expected_binaries` の対応表は `lib/cli_adapter.sh` の `build_cli_command` が
組み立てる先頭語と対で保つこと。CLI を足す時に片方だけ直すと、
新しい CLI が全部「落ち」に見える。T-PCL-009 が対応表を固定している。
