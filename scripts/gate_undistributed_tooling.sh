#!/usr/bin/env bash
# gate_undistributed_tooling.sh — ★配られておらぬ道具★の検知 (cmd_1367)
#
# ══ 何を検めるか ══
#   ★追跡下の道具が名指しする repo 内 path のうち、【実在するが HEAD に無い】物★。
#   = 呼ぶ者は fresh clone へ配られるが、呼ばれる者は配られぬ。
#   cmd_1363 で塞いだ「hook 宣言だけ配られ、呼ばれる script が追跡外」の【裏返し】である。
#
# ══ 何故 whitelist に1行足す形では足りぬか (家老の見立て・実測で裏付けた) ══
#   本 repo は whitelist 型 .gitignore (7行目の `*` で全除外→個別許可)。
#   ★同じ穴が別々の cmd で5回開いた実績が在る★ =
#     cmd_1280 idle_revive_scan.py / cmd_1339 idle_revive_scan.sh /
#     cmd_1355 tests/fixtures/*.txt / cmd_1363 shell_expansion_guard.py /
#     cmd_1354 gpu_sidecar_stop.sh — いずれも「見つけた者が1行足す」で個別に是正された。
#   ⇒ ★1件ずつ拾う直し方は、次に道具が増えた時にまた漏れる★。
#     本 gate は【道具が増えた事】でなく【配線されたのに配られておらぬ事】を見るゆえ、
#     whitelist を人が更新せずとも、新しい道具に自動で効く。
#
# ══ HEAD を正とする理由 ══
#   ★fresh clone が受け取るのは HEAD であって作業ツリーではない★
#   (gate_nightly の gate-1 が --committed を正とするのと同じ流儀)。
#   ゆえに走査元も追跡判定も HEAD。存在確認のみ作業ツリーを見る。
#
# ══ 三値 ══  PASS=0 / FAIL=1 / UNDETERMINED=2
#   ★観測できなんだ状態を緑に混ぜぬ★ (cmd_1342 B-O1 で warn() が吸収層になっておった教訓)。
#
# usage: gate_undistributed_tooling.sh [--selftest]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# ══ 規模の層 (cmd_1367 に軍師一号 N4 の教訓を適用) ══
#   ★「そのgateが黙る規模の軸を選べ」★ (家老が採った文言)。
#   本 gate が黙る軸は【標本の大きさ】ではなく ★走査元と参照の【痩せ】★ である:
#     ・git ls-tree の glob が変わる / 実行位置が repo 外 → 走査元 0 本 → 参照 0 件 → 常に緑
#     ・参照抽出の正規表現を壊す → 参照 0 件 → 常に緑
#   どちらも ★誰にも赤を出さず、ただ何も見なくなる★ 形ゆえ、下限を割ったら緑を出さぬ。
#   (実測 2026-07-26: 走査元 102 本 / 参照 254 件 ⇒ 下限は半分強に置く)
#   ★閾値は run_gate の【中】で読む★ = script 読込時に確定させると env 上書きが効かず、
#     selftest が「下限を跨がせて落ちるか」を撃てなくなる (初版で実際に踏んだ)。
GATE_SRC_MIN_DEFAULT=50
GATE_REF_MIN_DEFAULT=100

# ══ 生成物 allowlist ══
#   「追跡外で正しい」= ★fresh clone では追跡下の生成元が作るゆえ、repo に無くてよい★ 物。
#   形式: <path>|<生成元 path>
#   ★名前だけの list にはせぬ★ = 生成元が HEAD に在り、且つその blob が当該 path を
#     名指ししておることを毎回検める。生成元から生成が消えれば本 gate は赤くなる。
#   ★caveat (正直に書く)★ = 「blob に path 文字列が在る」は「現に生成しておる」より弱い。
#     生成コードの形 (変数経由の redirect 等) は script ごとに違い、形で判定すると
#     見落としと誤検知の両方を生む。ゆえに ★弱いと分かった上で採り、代わりに件数に
#     上限を置いて「黙らせる為に足す」を構造で抑える★。
GATE_ALLOW_MAX_DEFAULT=5
GENERATED_ALLOW_DEFAULT=(
	"config/settings.yaml|first_setup.sh"
	"config/projects.yaml|first_setup.sh"
	"agents/default/agent.yaml|scripts/build_instructions.sh"
)

# ══ ★この gate の網は狭い。狭いことを毎回 名乗る★ (cmd_1367 N3・軍師一号) ══
#   ★狭いことが誤りなのではない。狭いと名乗っておらぬことが誤りである★ (家老の言)。
#   ★実測で確かめた盲点★ =
#     ・cmd_1367 を起こした当の scripts/gpu_sidecar_stop.sh は、追跡下でその名を含む file が
#       ★自分自身のみ★ である (HEAD 全 file を走査して確認)。呼ぶ者が追跡外・人手・runbook で
#       あったゆえ、★仮に whitelist から外れても本 gate は名指しできぬ★。
#     ・是正前の状態へ当て直すと本 gate が surface するのは 5 件。同じ状態を拙者が手で調べた時は 19 件。
#   ⇒ ★本 gate は「配られておらぬ道具の全数」を出す物ではない。
#     【追跡下の .sh/.py/.bats が平文で名指ししておる分】だけを出す物である★。
#   ★毎 run 印字する理由★ = header の comment は log を読む者の目に入らぬ。
#     ★数字だけを見せて範囲を黙るのが、本日ずっと潰してきた形である★。
gate_scope_notice() {
	echo "  ★本 gate の網 (狭い・名乗っておく — cmd_1367 N3)★"
	echo "    見る = HEAD の .sh/.py/.bats が ★平文で★ 名指しする scripts|lib|config|instructions|templates|saytask|agents/ 配下の path"
	echo "    見ぬ ① 呼ぶ者が追跡外なら 呼ばれる者も見えぬ (gpu_sidecar_stop.sh が正にこの形であった)"
	echo "    見ぬ ② 呼ぶ者が .md / .ps1 / cron / 人手 / GUI なら見えぬ (走査元は .sh/.py/.bats のみ)"
	echo "    見ぬ ③ path を変数や連結で組む呼び方は見えぬ (平文一致のみ)"
	echo "    見ぬ ④ 上記 7 dir の外に在る道具は見えぬ"
	echo "    ⇒ ★本 gate の PASS は【配られておらぬ道具は無い】ではなく【この網に掛かる範囲では無い】である★"
	echo "  ★宛先違い (MISDIRECTED) の網は更に狭い — cmd_1441★"
	echo "    見る = MISSING のうち ★同じ名の file が HEAD の別の path に現に在る★ 物のみ"
	echo "    見ぬ ⑤ ★実体がどこにも無い宛先違いは永久に見えぬ★ (直し先が無い物は在り得ぬ path と区別が付かぬ)"
	echo "    見ぬ ⑥ 除外 4 つに当たる物は見ぬ (retired からの呼び / shellcheck source= 行 / 直前が スラッシュ の断片 / 本 gate 自身からの呼び)"
	echo "    見ぬ ⑥-b E4 (cmd_1445) = 本 gate 自身が唯一の呼び手である宛先違いは見えぬ。"
	echo "        他の者も同じ綴りを名指しておれば赤は残る (参照 1 件ごとに効くゆえ)"
	echo "    見ぬ ⑦ ★名は合うが別物である場合を見分けられぬ★ (名だけで照合しており中身を見ておらぬ) = 誤検知の側の穴"
}

# ══ 参照の抽出 (cmd_1441 で【文脈つき】へ替えた) ══
#   旧 = `grep -oE` で綴りだけを取っておった。新 = awk で 3 つを同時に出す:
#     ① 綴り  ② 直前の1文字が `/` か  ③ その行が shellcheck の source= 指示か
#   ★何故 文脈が要るか★ = 「宛先違い」の判定 (is_misdirected) の除外 E2/E3 が、
#     綴りだけでは決まらぬゆえ。E3 は ★抽出器が path の頭を切り落とした断片★ を見分ける
#     唯一の手掛かりであり、直前の文字を失えば断片と本物が同じ顔になる。
#   ★綴りの取り方 (正規表現・貪欲・左から重ならず) は旧と 1 文字も違えておらぬ★
#     = 入れ替えで参照の総和が動けば、以後の全ての数が旧と比べられなくなる。
#     ゆえに selftest T12 で ★旧 grep と新 awk が同じ列を返すこと★ を実弾で固定する。
extract_refs() {
	awk '
	{
		line = $0
		sc = (line ~ /shellcheck[^A-Za-z]*source=/) ? 1 : 0
		pos = 1
		while (1) {
			rest = substr(line, pos)
			if (!match(rest, /(scripts|lib|config|instructions|templates|saytask|agents)\/[A-Za-z0-9_.\/-]+/)) break
			abs = pos + RSTART - 1
			ref = substr(line, abs, RLENGTH)
			prev = (abs > 1) ? substr(line, abs - 1, 1) : ""
			printf "%s\t%d\t%d\n", ref, (prev == "/" ? 1 : 0), sc
			pos = abs + RLENGTH
		}
	}'
}

# ══ 「宛先違い」の判定 — MISSING 98 件のうち直せる物だけを赤へ (cmd_1441) ══
#   ★MISSING は本 gate の対象外のまま数え続ける★。此処で分けるのはその ★部分集合★ である。
#
#   ★何故 MISSING を丸ごと赤にせぬか (足軽六号 cmd_1438 の実測)★
#     素で倒すと 38 本が一斉に赤くなり、うち 34 本は ★元より在り得ぬ path★ である
#     (門/試験の作り物・散文の例示・退役品の旧 usage 等)。
#     ★全部で鳴る警告は読む者が無視する★ = cmd_1420 で直した病と同じ形になる。
#
#   ★物差し R★ = 「同じ basename の file が HEAD の別の path に現に在る」物だけを赤へ。
#     考え方は一本である ＝ ★案内が宛先を書き違えておる (＝直し先が在る) 物だけを名指す★。
#   ★除外 4 つ★ (いずれも機械で決まる。人の判断を要さぬ):
#     E1 呼ぶ者が scripts/retired/ 配下   … 退役品が己の旧 usage を記す形
#     E2 参照が shellcheck の source= 行  … その path は ★呼ぶ script の dir 基準★ ゆえ
#                                            repo root から解けぬのが正しい
#     E3 抽出位置の直前が `/`             … 別 dir の suffix を切り取った断片
#                                            (例: .opencode/agents/x.md から agents/x.md)
#     E4 呼ぶ者が本 gate 自身             … 門は己を検める者ではない (cmd_1445)
#
#   ★E4 を足した理由 (cmd_1445・軍師一号が cmd_1441 の検分で名指した)★
#     本 gate の selftest は偽 repo を組むために path の綴りを本体へ書く。その綴りは
#     ★HEAD の追跡下に在る★ゆえ、gate は己の作り物を「案内」と読んで赤を出す。
#     現に cmd_1441 の commit が MISDIRECTED 2 本を生み、★直すべき呼び手が居らぬ赤★になった
#     (作り物ゆえ「呼ぶ側を直せ」が当たらぬ)。毎朝 鳴って直せぬ門は、やがて外される。
#     ⇒ 気を付ける側でなく構造の側で塞ぐ。
#   ★E4 の効き方は【参照 1 件ごと】である (file ごとではない)★
#     同じ綴りを門以外の者も名指しておれば、その組は残るゆえ ★赤のまま★ になる。
#     = 門が唯一の呼び手である時だけ黙る。★本物を隠す幅を、構造で最小にしてある★ (T20 が証)。
#   ★E4 が見えなくする物 (名乗っておく)★
#     門自身の中に ★真の宛先違いが書かれ、且つ他に呼ぶ者が一人も居らぬ★ 場合は永久に見えぬ。
#     本 gate が名指す path はほぼ全て註と作り物ゆえ、この形は「直せる案内」ではない。
#
#   ★退けた案を書き残す (同じ案を作り直させぬため — 六号 cmd_1438 §5 の実測)★
#     「実行子 (bash/python3/source/exec) の直後の参照だけを赤へ」は ★向きが逆に働く★:
#     真の宛先違いを 0/4 しか掴まず、掴んだ 9 件は 9/9 とも在り得ぬ path であった。
#     理由 = ★宛先違いは悉く「註」の側に居り、実行子は例示文の側にこそ多い★。
# 本 gate 自身の path (repo root 相対)。E4 の判定に使う。
# selftest の偽 repo でも同じ綴りの file を置いて撃つゆえ、定数で足りる。
GATE_SELF_REL="scripts/gate_undistributed_tooling.sh"

is_misdirected() {
	local ref="$1" caller="$2" prevslash="$3" scline="$4" hbase="$5"
	case "$caller" in scripts/retired/*) return 1 ;; esac   # E1
	[ "$scline" = "1" ] && return 1                          # E2
	[ "$prevslash" = "1" ] && return 1                       # E3
	[ "$caller" = "$GATE_SELF_REL" ] && return 1             # E4
	local base="${ref##*/}"
	# R = 同じ basename が HEAD の【別の】path に在るか
	printf '%s\n' "$hbase" | awk -F'\t' -v b="$base" -v r="$ref" '
		$1 == b && $2 != r { found = 1 } END { exit found ? 0 : 1 }'
}

run_gate() {
	local root="$1"
	local SRC_MIN="${GATE_SRC_MIN:-$GATE_SRC_MIN_DEFAULT}"
	local REF_MIN="${GATE_REF_MIN:-$GATE_REF_MIN_DEFAULT}"
	local ALLOW_MAX="${GATE_ALLOW_MAX:-$GATE_ALLOW_MAX_DEFAULT}"
	# selftest 用の差替口 (空文字 = allowlist 無し)。本番実行では未設定ゆえ既定が効く。
	local -a GENERATED_ALLOW
	if [ "${GATE_ALLOW_OVERRIDE+set}" = set ]; then
		# shellcheck disable=SC2206
		GENERATED_ALLOW=(${GATE_ALLOW_OVERRIDE})
	else
		GENERATED_ALLOW=("${GENERATED_ALLOW_DEFAULT[@]}")
	fi
	cd "$root" || { echo "[UNDETERMINED] repo root へ入れぬ: $root"; return 2; }
	git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "[UNDETERMINED] HEAD が無い"; return 2; }

	local head_list src_list
	head_list="$(git ls-tree -r --name-only HEAD)" || { echo "[UNDETERMINED] ls-tree 失敗"; return 2; }
	src_list="$(printf '%s\n' "$head_list" | grep -E '\.(sh|py|bats)$' || true)"

	local n_src; n_src="$(printf '%s' "$src_list" | grep -c . || true)"
	if [ "$n_src" -lt "$SRC_MIN" ]; then
		echo "[UNDETERMINED] 走査元が $n_src 本 (下限 $SRC_MIN) = gate が痩せて何も見ておらぬ疑い"
		return 2
	fi

	# ── allowlist の健全性 (吸収層化の抑止) ──
	if [ "${#GENERATED_ALLOW[@]}" -gt "$ALLOW_MAX" ]; then
		echo "[FAIL] 生成物 allowlist が $((${#GENERATED_ALLOW[@]})) 件 (上限 $ALLOW_MAX) = gate を黙らせる方向へ育っておる"
		return 1
	fi
	local allow_bad=0 entry apath agen
	for entry in ${GENERATED_ALLOW[@]+"${GENERATED_ALLOW[@]}"}; do
		apath="${entry%%|*}"; agen="${entry##*|}"
		if ! printf '%s\n' "$head_list" | grep -qxF "$agen"; then
			echo "[FAIL] allowlist の生成元が HEAD に無い: $apath ← $agen"; allow_bad=1; continue
		fi
		if ! git show "HEAD:$agen" 2>/dev/null | grep -qF "$apath"; then
			echo "[FAIL] allowlist の生成元が当該 path を名指ししておらぬ: $apath ← $agen (生成が消えた疑い)"; allow_bad=1
		fi
	done

	# ── 参照抽出 → 四分別 ──
	# ★MISSING の中から「宛先違い」を分ける (cmd_1441)★ = 詳細は extract_refs / is_misdirected の頭書。
	local head_base
	head_base="$(printf '%s\n' "$head_list" | awk -F/ '{print $NF"\t"$0}')"

	local n_ref=0 n_ok=0 n_bad=0 n_missing=0 n_gen=0 n_mis=0
	local findings="" mis_findings=""
	local s body ref prevslash scline
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		body="$(git show "HEAD:$s" 2>/dev/null)" || continue
		while IFS=$'\t' read -r ref prevslash scline; do
			[ -n "$ref" ] || continue
			case "$ref" in *.sh|*.py|*.yaml|*.yml|*.md|*.cron|*.json|*.bats|*.bash) ;; *) continue ;; esac
			n_ref=$((n_ref + 1))
			if [ ! -f "$ref" ]; then
				n_missing=$((n_missing + 1))            # 実在せぬ = 別種の問題
				if is_misdirected "$ref" "$s" "$prevslash" "$scline" "$head_base"; then
					n_mis=$((n_mis + 1))
					mis_findings="${mis_findings}${ref}"$'\t'"${s}"$'\n'
					# ★GATE_CENSUS=1 で 1 件ずつ標準エラーへ吐く (cmd_1441)★
					#   ★何故 門の【中】に置くか★ = 数え直す度に写しを起こせば、写しと本体が
					#   いつか食い違う。六号が cmd_1438 で「写しの上でしか測っておらぬ」と
					#   自ら名乗った所である。★同じ抽出器で数えられる口を本体へ据える★。
					if [ -n "${GATE_CENSUS:-}" ]; then
						printf 'MISDIRECTED\t%s\t%s\n' "$ref" "$s" >&2
					fi
				elif [ -n "${GATE_CENSUS:-}" ]; then
					printf 'MISSING\t%s\t%s\tprevslash=%s\tshellcheck=%s\n' "$ref" "$s" "$prevslash" "$scline" >&2
				fi
			elif printf '%s\n' "$head_list" | grep -qxF "$ref"; then
				n_ok=$((n_ok + 1))
			elif printf '%s\n' ${GENERATED_ALLOW[@]+"${GENERATED_ALLOW[@]}"} | grep -qE "^${ref}\|"; then
				n_gen=$((n_gen + 1))                    # 生成物ゆえ追跡外で正しい
			else
				n_bad=$((n_bad + 1))
				# ★file 名と呼ぶ者を対で溜める (cmd_1367 N2 是正)★ =
				#   初版は 1 参照ごとに 1 行の所見を積んでおった。同じ道具が3箇所から
				#   呼ばれておれば所見が3行に膨れ、★「1本落ちておる」を「3件」と申告し、
				#   且つ後段の head で他の道具を押し出す★ (軍師一号 N1/N2)。
				findings="${findings}${ref}"$'\t'"${s}"$'\n'
			fi
		done < <(printf '%s' "$body" | extract_refs)
	done <<<"$src_list"

	if [ "$n_ref" -lt "$REF_MIN" ]; then
		echo "[UNDETERMINED] 参照が $n_ref 件 (下限 $REF_MIN) = 参照抽出が壊れて何も見ておらぬ疑い"
		return 2
	fi

	# ★何本 (file) と 何件 (参照出現) を分けて数える★ — cmd_1367 N2 是正。
	#   ★総和の検算は【参照出現】で行う★ = 内訳は参照を分類した物ゆえ、file 数と足しても合わぬ。
	local bad_files n_bad_files mis_files n_mis_files
	bad_files="$(printf '%s' "$findings" | cut -f1 | grep -v '^$' | sort -u)"
	n_bad_files="$(printf '%s' "$bad_files" | grep -c . || true)"
	mis_files="$(printf '%s' "$mis_findings" | cut -f1 | grep -v '^$' | sort -u)"
	n_mis_files="$(printf '%s' "$mis_files" | grep -c . || true)"

	# ★総和と内訳を同じ出力に並べ、足して合うかを機械で検算する★ (cmd_1358 の全軍規律)
	echo "[gate_undistributed] 走査元=$n_src 本 / 参照 総和=$n_ref"
	echo "  内訳 OK=$n_ok  生成物=$n_gen  ★UNDISTRIBUTED=${n_bad_files}本(参照${n_bad}件)★  MISSING=$n_missing"
	echo "  MISSING の内訳 ★宛先違い=${n_mis_files}本(参照${n_mis}件)★  在り得ぬ path(対象外)=$((n_missing - n_mis))"
	if [ "$n_ref" -ne $((n_ok + n_gen + n_bad + n_missing)) ]; then
		echo "[UNDETERMINED] 検算 FAIL: 総和 != 内訳の和 = この出力を信じるな"
		return 2
	fi
	if [ "$n_mis" -gt "$n_missing" ]; then
		echo "[UNDETERMINED] 検算 FAIL: 宛先違いが MISSING を超えておる = この出力を信じるな"
		return 2
	fi
	echo "  検算 OK (総和 == 内訳の和・参照出現で照合。宛先違いは MISSING の部分集合)"
	gate_scope_notice

	# ★1 道具につき 1 行★ = 呼ぶ者は同じ行へ畳む (所見が重複で膨れ、
	#   後段 (gate_nightly の head) で他の道具を押し出すのを防ぐ — 軍師一号 N1)。
	local p callers
	if [ "$n_bad" -gt 0 ]; then
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			# ★呼ぶ者も重複を畳む★ = 同じ script が同じ道具を3回呼んでおれば
			#   「f1.sh f1.sh f1.sh」と3度並び、畳んだ文面の枠を無駄に食う (N1 の同族)。
			callers="$(printf '%s' "$findings" | awk -F'\t' -v r="$p" '$1==r{print $2}' | sort -u | awk '{printf "%s ", $0}')"
			echo "  [UNDISTRIBUTED] ${p}  ← 追跡下の ${callers}が名指し"
		done <<<"$bad_files"
		echo "  ⇒ 配られておらぬ道具 ${n_bad_files} 本 (参照 ${n_bad} 件) = 呼ぶ者は fresh clone へ配られるが呼ばれる者は配られぬ"
		echo "    処方: .gitignore の whitelist へ否定規則を足すか、真に配るべきでなければ呼ぶ側を直せ"
	fi
	if [ "$n_mis" -gt 0 ]; then
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			callers="$(printf '%s' "$mis_findings" | awk -F'\t' -v r="$p" '$1==r{print $2}' | sort -u | awk '{printf "%s ", $0}')"
			# ★直し先を出力に載せる★ = 「赤い」だけでは読む者が次に何をすべきか分からぬ。
			#   物差し R は元より「同じ basename が別の場所に在る」で赤くしておるゆえ、
			#   ★其の別の場所を出せる★ (出せぬなら赤にしておらぬ)。
			local cand
			cand="$(printf '%s\n' "$head_base" | awk -F'\t' -v b="${p##*/}" -v r="$p" '$1==b && $2!=r{print $2}' | sort -u | head -3 | awk '{printf "%s ", $0}')"
			echo "  [MISDIRECTED] ${p}  ← 追跡下の ${callers}が名指し / 実体は ${cand}に在る"
		done <<<"$mis_files"
		echo "  ⇒ 宛先違いの案内 ${n_mis_files} 本 (参照 ${n_mis} 件) = 名指された path に file が無く、同じ名の file が別の場所に在る"
		echo "    処方: 呼ぶ側の綴りを実体の path へ直せ (実体を動かす側が正しい場合も在る。どちらが正かは人が判ずる)"
	fi

	if [ "$n_bad" -gt 0 ] || [ "$n_mis" -gt 0 ]; then
		echo "[FAIL] 配られておらぬ道具 ${n_bad_files} 本 / 宛先違いの案内 ${n_mis_files} 本"
		return 1
	fi
	[ "$allow_bad" -ne 0 ] && return 1
	echo "[PASS] 配線されておる道具は全て HEAD に在り、宛先違いの案内も無い"
	return 0
}

# ══════════════ selftest ══════════════
# ★軍師二号 C4 の教義★ = 「素の緑」を撃たねば、常に赤/常にUNDETを吐く壊れた物差しと
#   区別がつかぬ。ゆえに T1 で ★緑が出せること★ を先に示す。
selftest() {
	local tmp pass=0 fail=0
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN

	mk_repo() {
		local d="$1"; rm -rf "$d"; mkdir -p "$d/scripts"; cd "$d" || return 1
		git init -q . && git config user.email t@t && git config user.name t
		local i
		for i in $(seq 1 60); do
			printf '#!/usr/bin/env bash\nbash "$D/scripts/dep.sh"\n' >"scripts/f$i.sh"
		done
		printf '#!/usr/bin/env bash\necho dep\n' >scripts/dep.sh
		git add -A >/dev/null && git commit -q -m init
		cd - >/dev/null || return 1
	}
	chk() {
		local name="$1" want="$2" got="$3" out="$4"
		if [ "$got" = "$want" ]; then echo "  ok   $name (exit $got)"; pass=$((pass + 1))
		else echo "  ★NG★ $name: want exit $want got $got"; printf '%s\n' "$out" | sed 's/^/         /'; fail=$((fail + 1)); fi
	}

	echo "── selftest: gate_undistributed_tooling ──"

	# sandbox には first_setup.sh 等は無いゆえ allowlist は空で撃つ (T6/T7 が専任で検める)
	export GATE_ALLOW_OVERRIDE=""

	# T1 ★素の緑★ = 全ての参照先が HEAD に在る (C4: 緑も出せることの実証)
	mk_repo "$tmp/r1"
	local o rc
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r1" 2>&1)"; rc=$?
	chk "T1 素の緑 (参照先が全て HEAD に在る)" 0 "$rc" "$o"

	# T2 ★配られておらぬ道具★ = 実在するが HEAD に無い参照先
	mk_repo "$tmp/r2"; printf '#!/usr/bin/env bash\necho wild\n' >"$tmp/r2/scripts/wild.sh"
	printf '#!/usr/bin/env bash\nbash "$D/scripts/wild.sh"\n' >"$tmp/r2/scripts/f1.sh"
	(cd "$tmp/r2" && git add scripts/f1.sh >/dev/null && git commit -q -m wire)
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r2" 2>&1)"; rc=$?
	chk "T2 追跡外の道具を配線したら FAIL" 1 "$rc" "$o"
	printf '%s' "$o" | grep -q 'UNDISTRIBUTED.*wild.sh' \
		&& { echo "  ok   T2b 名指しできておる"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T2b 名指しできておらぬ"; fail=$((fail + 1)); }

	# T3 ★実在せぬ参照は誤検知せぬ★ = MISSING は本 gate の対象外
	mk_repo "$tmp/r3"
	printf '#!/usr/bin/env bash\nbash "$D/scripts/nonexistent_xyz.sh"\n' >"$tmp/r3/scripts/f1.sh"
	(cd "$tmp/r3" && git add -A >/dev/null && git commit -q -m miss)
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r3" 2>&1)"; rc=$?
	chk "T3 実在せぬ参照では赤くならぬ (誤検知せぬ)" 0 "$rc" "$o"

	# T4 ★規模の軸①★ = 走査元が痩せたら緑を出さぬ
	mk_repo "$tmp/r4"
	o="$(GATE_SRC_MIN=1000 GATE_REF_MIN=10 run_gate "$tmp/r4" 2>&1)"; rc=$?
	chk "T4 走査元が下限割れ → UNDETERMINED" 2 "$rc" "$o"

	# T5 ★規模の軸②★ = 参照が痩せたら緑を出さぬ (抽出正規表現を壊した形)
	mk_repo "$tmp/r5"
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=100000 run_gate "$tmp/r5" 2>&1)"; rc=$?
	chk "T5 参照が下限割れ → UNDETERMINED" 2 "$rc" "$o"

	# ── allowlist が【吸収層でない】ことの実証 ──
	# 生成物 gen.yaml を作業ツリーにだけ置き、追跡下 f1.sh から名指しさせる。
	mk_repo "$tmp/r6"
	printf 'x: 1\n' >"$tmp/r6/config_gen.yaml"; mkdir -p "$tmp/r6/config"; printf 'x: 1\n' >"$tmp/r6/config/gen.yaml"
	printf '#!/usr/bin/env bash\ncat > "$D/config/gen.yaml" <<EOF\nx: 1\nEOF\n' >"$tmp/r6/scripts/mkgen.sh"
	printf '#!/usr/bin/env bash\nsource "$D/config/gen.yaml"\n' >"$tmp/r6/scripts/f1.sh"
	(cd "$tmp/r6" && git add scripts/mkgen.sh scripts/f1.sh >/dev/null && git commit -q -m gen)

	# T6 ★allowlist が効く★ = 生成元が現に当該 path を名指ししておれば緑
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 GATE_ALLOW_OVERRIDE='config/gen.yaml|scripts/mkgen.sh' run_gate "$tmp/r6" 2>&1)"; rc=$?
	chk "T6 生成物は allowlist で緑になる" 0 "$rc" "$o"

	# T7 ★allowlist は素通しでない★ = 生成元から生成が消えたら赤くなる
	printf '#!/usr/bin/env bash\necho "no longer generates anything"\n' >"$tmp/r6/scripts/mkgen.sh"
	(cd "$tmp/r6" && git add scripts/mkgen.sh >/dev/null && git commit -q -m degen)
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 GATE_ALLOW_OVERRIDE='config/gen.yaml|scripts/mkgen.sh' run_gate "$tmp/r6" 2>&1)"; rc=$?
	chk "T7 生成元が生成を止めたら FAIL (allowlist が吸収層でない証明)" 1 "$rc" "$o"

	# T8 ★allowlist を黙らせる方向へ育てたら FAIL★
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 GATE_ALLOW_MAX=1 GATE_ALLOW_OVERRIDE='a|b c|d e|f' run_gate "$tmp/r1" 2>&1)"; rc=$?
	chk "T8 allowlist が上限超過 → FAIL" 1 "$rc" "$o"

	# ── cmd_1367 差し戻し (軍師一号 N1/N2/N3) の是正を、実弾で固定する ──

	# T9 ★N2: 同じ道具が複数箇所から呼ばれても【1本】と数える★
	#   (初版は参照出現を本数として申告し、1本落として「6件」と言うておった)
	mk_repo "$tmp/r9"; printf '#!/usr/bin/env bash\necho wild\n' >"$tmp/r9/scripts/wild.sh"
	local k
	for k in 1 2 3; do printf '#!/usr/bin/env bash\nbash "$D/scripts/wild.sh"\n' >"$tmp/r9/scripts/f$k.sh"; done
	(cd "$tmp/r9" && git add scripts/f1.sh scripts/f2.sh scripts/f3.sh >/dev/null && git commit -q -m wire3)
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r9" 2>&1)"; rc=$?
	chk "T9 3箇所から呼ばれる1本 → FAIL" 1 "$rc" "$o"
	printf '%s' "$o" | grep -q 'UNDISTRIBUTED=1本(参照3件)' \
		&& { echo "  ok   T9b ★1本(参照3件)と分けて数えておる (N2)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T9b 本数と参照件数を分けておらぬ"; printf '%s\n' "$o" | sed 's/^/         /'; fail=$((fail + 1)); }
	[ "$(printf '%s' "$o" | grep -c '\[UNDISTRIBUTED\]')" = "1" ] \
		&& { echo "  ok   T9c ★所見は1道具1行に畳まれておる (N1)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T9c 所見が重複で膨れておる"; fail=$((fail + 1)); }

	# T10 ★N1: 複数の道具が落ちたら【全て】名指しできる★
	#   (重複が枠を食い、3本落として2本しか載らなんだのが差し戻しの元)
	mk_repo "$tmp/r10"
	for k in a b c; do printf '#!/usr/bin/env bash\necho %s\n' "$k" >"$tmp/r10/scripts/wild_$k.sh"; done
	printf '#!/usr/bin/env bash\nbash "$D/scripts/wild_a.sh"\nbash "$D/scripts/wild_a.sh"\nbash "$D/scripts/wild_a.sh"\nbash "$D/scripts/wild_b.sh"\nbash "$D/scripts/wild_c.sh"\n' >"$tmp/r10/scripts/f1.sh"
	(cd "$tmp/r10" && git add scripts/f1.sh >/dev/null && git commit -q -m wire_abc)
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r10" 2>&1)"; rc=$?
	chk "T10 3本落ち (うち1本は3重参照) → FAIL" 1 "$rc" "$o"
	local named=0
	for k in a b c; do printf '%s' "$o" | grep -q "UNDISTRIBUTED\] scripts/wild_$k.sh" && named=$((named + 1)); done
	[ "$named" = "3" ] \
		&& { echo "  ok   T10b ★3本とも名指しできておる (N1)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T10b 名指しできたのは $named/3 本"; printf '%s\n' "$o" | sed 's/^/         /'; fail=$((fail + 1)); }

	# T11 ★N3: 網の狭さを毎回 名乗る★ = 緑でも赤でも scope を出す。
	#   ★これを試験に据える理由★ = comment に書くだけでは、次に誰かが出力を整理した時に
	#     黙って消える。★消えたら赤くなる形にして初めて「名乗り続ける」と言える★。
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r1" 2>&1)"
	printf '%s' "$o" | grep -q '本 gate の網' && printf '%s' "$o" | grep -q '見ぬ ①' \
		&& { echo "  ok   T11 ★緑でも網の狭さを名乗っておる (N3)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T11 緑の時に scope を名乗っておらぬ"; fail=$((fail + 1)); }
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r10" 2>&1)"
	printf '%s' "$o" | grep -q '本 gate の網' \
		&& { echo "  ok   T11b ★赤でも網の狭さを名乗っておる (N3)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T11b 赤の時に scope を名乗っておらぬ"; fail=$((fail + 1)); }

	# ── cmd_1441: 物差し R (宛先違い) と その除外 3 つ ──

	# T12 ★抽出器を grep から awk へ入れ替えた事で、取れる綴りが変わっておらぬか★
	#   ★之を試験に据える理由★ = 総和 (参照 1051 件) が動けば、以後の全ての数が
	#   旧い測りと比べられなくなる。★入れ替えは静かに数を変える★ゆえ、実弾で固定する。
	#   ★引っ掛け易い形を並べてある★: 行頭の一致 / 直前がスラッシュ / 1 行に複数 / 拡張子なし。
	local fx="$tmp/extract_fixture.txt"
	cat >"$fx" <<'FIXEOF'
scripts/a.sh at line head
bash "$D/scripts/b.sh" && python3 "$D/lib/c.py"
source .opencode/agents/shogun.md
# shellcheck source=lib/proc_lock.sh
prefix-scripts/d.sh and config/e.yaml
instructions/generated/claude-karo.md
no path here at all
FIXEOF
	local got want
	want="$(grep -oE '(scripts|lib|config|instructions|templates|saytask|agents)/[A-Za-z0-9_./-]+' "$fx" || true)"
	got="$(extract_refs <"$fx" | cut -f1)"
	if [ "$want" = "$got" ]; then
		echo "  ok   T12 ★新旧の抽出器が同じ綴りを同じ順で返す (総和が動かぬ証)★"; pass=$((pass + 1))
	else
		echo "  ★NG★ T12 抽出器の入れ替えで綴りが変わった"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/         /'; fail=$((fail + 1))
	fi

	# T12b ★文脈 (直前がスラッシュか / shellcheck の行か) を現に見分けておるか★
	#   綴りが同じでも文脈欄が常に 0 なら、除外 E2/E3 は永久に発火せぬ (=素通し)。
	local ctx
	ctx="$(extract_refs <"$fx" | awk -F'\t' '$2==1 || $3==1 {print $1"|"$2$3}' | sort -u | tr '\n' ' ')"
	printf '%s' "$ctx" | grep -q 'agents/shogun.md|10' && printf '%s' "$ctx" | grep -q 'lib/proc_lock.sh|01'
	if [ $? -eq 0 ]; then
		echo "  ok   T12b ★直前スラッシュと shellcheck 行を現に見分けておる★"; pass=$((pass + 1))
	else
		echo "  ★NG★ T12b 文脈欄が働いておらぬ: $ctx"; fail=$((fail + 1))
	fi

	# ── R と E1/E2/E3 を撃つための木 ──
	#   HEAD に scripts/lib/tool.sh を置き、呼ぶ側は scripts/tool.sh (実在せぬ) を名指す。
	#   = ★同じ名の file が別の場所に在る★ = 物差し R が当たる形。
	#   第 4/5 引数 (任意) = ★二人目の呼び手★。E4 が「門以外の呼び手まで黙らせておらぬ」を撃つのに使う。
	mk_red_repo() {
		local d="$1" caller_path="$2" caller_body="$3" caller2_path="${4:-}" caller2_body="${5:-}"
		rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/$(dirname "$caller_path")"; cd "$d" || return 1
		git init -q . && git config user.email t@t && git config user.name t
		local i
		for i in $(seq 1 60); do printf '#!/usr/bin/env bash\nbash "$D/scripts/dep.sh"\n' >"scripts/f$i.sh"; done
		printf '#!/usr/bin/env bash\necho dep\n' >scripts/dep.sh
		printf '#!/usr/bin/env bash\necho tool\n' >scripts/lib/tool.sh
		mkdir -p .opencode/agents && printf '# shogun\n' >.opencode/agents/shogun.md
		printf '#!/usr/bin/env bash\necho lock\n' >scripts/lib/proc_lock.sh
		printf '%b' "$caller_body" >"$caller_path"
		if [ -n "$caller2_path" ]; then
			mkdir -p "$(dirname "$caller2_path")"
			printf '%b' "$caller2_body" >"$caller2_path"
		fi
		git add -A >/dev/null && git commit -q -m init
		cd - >/dev/null || return 1
	}

	# T13 ★物差し R が現に赤を出す★ = 実在せぬ参照でも、同じ名が別の場所に在れば赤
	#   (T3 と対を成す。T3 = 名がどこにも無ければ緑。この2本で「MISSING を丸ごと赤に
	#    しておらぬ」と「宛先違いだけは赤にする」の両方が固定される)
	mk_red_repo "$tmp/r12" "scripts/caller.sh" '#!/usr/bin/env bash\n# 案内: scripts/tool.sh を読め\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r12" 2>&1)"; rc=$?
	chk "T13 宛先違い (同じ名が別の場所に在る) → FAIL" 1 "$rc" "$o"
	printf '%s' "$o" | grep -q 'MISDIRECTED\] scripts/tool.sh' && printf '%s' "$o" | grep -q '実体は scripts/lib/tool.sh' \
		&& { echo "  ok   T13b ★名指しと【直し先】の両方を出しておる★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T13b 直し先を出しておらぬ"; printf '%s\n' "$o" | sed 's/^/         /'; fail=$((fail + 1)); }

	# T14 ★E1: 退役品が己の旧 usage を記す形は赤にせぬ★
	mk_red_repo "$tmp/r13" "scripts/retired/old.sh" '#!/usr/bin/env bash\n# 旧 usage: scripts/tool.sh\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r13" 2>&1)"; rc=$?
	chk "T14 E1 retired からの呼びは赤にせぬ" 0 "$rc" "$o"

	# T15 ★E2: shellcheck の source= 行は赤にせぬ★ (path は呼ぶ script の dir 基準)
	mk_red_repo "$tmp/r14" "scripts/caller.sh" '#!/usr/bin/env bash\n# shellcheck source=lib/proc_lock.sh\nsource "$D/scripts/lib/proc_lock.sh"\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r14" 2>&1)"; rc=$?
	chk "T15 E2 shellcheck source= 行は赤にせぬ" 0 "$rc" "$o"

	# T16 ★E3: 別 dir の suffix を切り取った断片は赤にせぬ★
	mk_red_repo "$tmp/r15" "scripts/caller.sh" '#!/usr/bin/env bash\ncat "$D/.opencode/agents/shogun.md"\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r15" 2>&1)"; rc=$?
	chk "T16 E3 直前がスラッシュの断片は赤にせぬ" 0 "$rc" "$o"

	# T17 ★除外が【素通しでない】ことの証★ = 同じ木で除外の条件だけを外せば赤くなるか。
	#   ★之を撃たねば、E1/E2/E3 は「常に除外する」壊れ方をしていても T14〜T16 は緑のままである★
	#   (三号が 23:47 に名乗った「黙るだけを主張する試験は、門が壊れても緑」の形)。
	mk_red_repo "$tmp/r16" "scripts/caller.sh" '#!/usr/bin/env bash\n# 註: lib/proc_lock.sh (shellcheck の指示ではない普通の行)\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r16" 2>&1)"; rc=$?
	chk "T17 同じ綴りでも shellcheck 行でなければ赤くなる (E2 が素通しでない証)" 1 "$rc" "$o"

	# ── cmd_1445: E4 (門は己を検める者ではない) ──

	# T19 ★E4 が現に効く★ = 門自身が名指した宛先違いは赤にせぬ。
	#   T13 と同じ木・同じ綴りで、呼び手だけを門自身へ替えてある。
	#   ⇒ T13 が赤・T19 が緑 = ★差は呼び手だけ★ゆえ、E4 以外の理由では説明が付かぬ。
	mk_red_repo "$tmp/r17" "$GATE_SELF_REL" '#!/usr/bin/env bash\n# 作り物: scripts/tool.sh を名指す\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r17" 2>&1)"; rc=$?
	chk "T19 E4 門自身からの呼びは赤にせぬ" 0 "$rc" "$o"

	# T20 ★E4 が【本物を隠さぬ】証★ = 同じ綴りを門自身と別の呼び手の両方が名指せば、赤は残る。
	#   ★之を撃たねば、E4 は「その綴りを永久に免じる」壊れ方をしていても T19 は緑のままである★
	#   (E1〜E3 に対する T17 と同じ形。除外を足す時は必ず素通しでない証を対で置く)。
	mk_red_repo "$tmp/r18" "$GATE_SELF_REL" '#!/usr/bin/env bash\n# 作り物: scripts/tool.sh を名指す\n' \
		"scripts/other_caller.sh" '#!/usr/bin/env bash\n# 案内: scripts/tool.sh を読め\n'
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r18" 2>&1)"; rc=$?
	chk "T20 E4 は門以外の呼び手まで黙らせぬ (素通しでない証)" 1 "$rc" "$o"
	printf '%s' "$o" | grep -q 'MISDIRECTED\] scripts/tool.sh' \
		&& printf '%s' "$o" | grep -q 'scripts/other_caller.sh' \
		&& ! printf '%s' "$o" | grep -q "が名指し.*$GATE_SELF_REL" \
		&& { echo "  ok   T20b ★残った赤の呼び手は門以外だけ (門の分だけが落ちておる)★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T20b 呼び手の畳み方が期待と違う"; printf '%s\n' "$o" | sed 's/^/         /'; fail=$((fail + 1)); }

	# T18 ★網の狭さ (宛先違いの側) も毎回 名乗る★ — T11 の系統
	o="$(GATE_SRC_MIN=10 GATE_REF_MIN=10 run_gate "$tmp/r1" 2>&1)"
	printf '%s' "$o" | grep -q '宛先違い (MISDIRECTED) の網は更に狭い' && printf '%s' "$o" | grep -q '見ぬ ⑤' \
		&& { echo "  ok   T18 ★宛先違いの網の狭さを緑でも名乗っておる★"; pass=$((pass + 1)); } \
		|| { echo "  ★NG★ T18 宛先違いの scope を名乗っておらぬ"; fail=$((fail + 1)); }

	unset GATE_ALLOW_OVERRIDE

	echo "── selftest 結果: PASS=$pass NG=$fail ──"
	[ "$fail" -eq 0 ] || return 1
	return 0
}

case "${1:-}" in
	--selftest) selftest; exit $? ;;
	*) run_gate "$SCRIPT_DIR"; exit $? ;;
esac
