# vLLM の停止スクリプトは対象名が当たりません (2026-07-29)

見つけた人: 足軽一号（発見）と軍師一号（再現）の2人 / 対象: **aituber-project** の `scripts/stop_vllm.sh`（`/home/k-kikuchi/aituber-project/scripts/stop_vllm.sh`）

**この repo（multi-agent-shogun）には在りません。** ここで探しても見つからないのは正常です。「無い＝直った」ではありません。

- `stop_vllm.sh:20` が止めようとする対象 = **`vllm-unified`**
- `VLLM_DOCKER_NAME` は 238 行目でコメント化されており、既定値が使われます
- 現に動いているコンテナ = **`vllm-main`**
- `backend/.env:160`（これも aituber-project 側）= `LLM_PIPELINE_ENABLED=false`

⇒ **名前が当たっていないので、撃っても止まりません。** 止める時は `docker stop` を直に使ってください。

**この判定は撃っていません。** スクリプトの本文と `.env` の値を読んで出した判定で、実際に `stop_vllm.sh` を走らせて確かめてはいません。

直しは入れていません。将軍が殿へ伺うまで、このままにします。
