# 5090 の仕事は待ち行列に積む（cmd_2059・家老が 5090 を使う task に添える文）

5090 は直に撃たない。待ち行列に積み、撃つのは足軽2号の撃ち手（`queue_shoot.py`）に任せる。
画像・描き直し・ComfyUI の workflow（I2V・R18 のサンプルを含む）・LoRA 学習・GPU を使う script、全部同じ。
VRAM を測る1本だけの試し撃ちも積む。

## 積み方

script = `/mnt/f/aituber-project-ml/scripts/cmd_2053/shoot_queue.py`（行列ファイルは同じ dir の決まりの場所。直に書き換えない）

```bash
cd /mnt/f/aituber-project-ml/scripts/cmd_2053
# 1本だけ積む: add1 <kind> <cmd> <出力> '<input の JSON>' [--prio N] [--est 分] --by <自分>
python3 shoot_queue.py add1 kaonaoshi cmd_2053 /mnt/f/.../out.png '{"src":"/mnt/f/.../in.png"}' --by ashigaru3
python3 shoot_queue.py add1 comfy_wf cmd_2060 /mnt/f/.../i2v.mp4 '{"workflow":"/mnt/f/.../wan_api.json","set":{"6.inputs.text":"..."},"out_node":"58"}' --est 8 --by ashigaru4
python3 shoot_queue.py add1 lora_train cmd_2053 /mnt/f/lora_trainers/out/cmd2053 '{"chara":"koi","mode":"train"}' --est 480 --by ashigaru5
python3 shoot_queue.py add1 script cmd_2061 /mnt/f/.../out_dir '{"argv":["python3","/mnt/f/aituber-project-ml/scripts/xxx.py","--a","1"]}' --est 20 --by ashigaru6
# 何本もまとめて積む: 列の名前を見出しにした tsv を add
python3 shoot_queue.py add rows.tsv
```

| kind | input に書く物 |
|---|---|
| `gafu` | 画風（cmd_2053 の行列 G）。`prompt_file`・`ref_file`・`seed` の列を使う。`queue_add_F.py` が積む |
| `kaonaoshi` | `src`（描き直す絵）・`narabe`（任意。例 `koi-sui`） |
| `comfy_wf` | `workflow`（API 形式の .json か workflow 入りの .png）・`set`（`"ノード.inputs.名前": 値`）・`out_node`（既定 `13`） |
| `lora_train` | `chara`（koi/sui/akari/kanade）・`mode`（`check` = GPU を使わない確かめ / `dryrun` / `train`）・`steps`・`data` |
| `script` | `argv`。1つ目は `python3` か `bash` か venv の python。2つ目は ml の `scripts/` か `/mnt/f/r18_ai_lab/tools/` の下の物だけ |

## 決まり

1. **優先度（`--prio`）は 3〜9 を自分で付けてよい。既定 5。1〜2 は家老の許しを得てから。** 小さいほど先。
2. **見込み時間（`--est` 分）を書く。** 60 分以上は「長い仕事」。同じ優先度の短い仕事が残っている間は始まらない。撃ち中に割り込まれない。
3. **配信中は新しい仕事が始まらない。** LoRA 学習は撃ち中に配信が始まると止まり、配信が終わってから途中の保存から続ける。
4. 子プロセスには撃ち手が `CUDA_DEVICE_ORDER=PCI_BUS_ID`・`CUDA_VISIBLE_DEVICES=1`（5090 だけ）を付ける。4070 は触らない。
5. 結果は `python3 shoot_queue.py show` で見る。done の行の `out_path` を拾う。failed の理由は `note` 列。
6. 撃つ前に取り下げる時は `cancel <qid> <理由>`。行を消さない。
