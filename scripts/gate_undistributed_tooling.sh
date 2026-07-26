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

	# ── 参照抽出 → 三分別 ──
	local n_ref=0 n_ok=0 n_bad=0 n_missing=0 n_gen=0
	local findings=""
	local s body ref
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		body="$(git show "HEAD:$s" 2>/dev/null)" || continue
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			case "$ref" in *.sh|*.py|*.yaml|*.yml|*.md|*.cron|*.json|*.bats|*.bash) ;; *) continue ;; esac
			n_ref=$((n_ref + 1))
			if [ ! -f "$ref" ]; then
				n_missing=$((n_missing + 1))            # 実在せぬ = 別種の問題 (本 gate の対象外)
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
		done < <(printf '%s' "$body" | grep -oE '(scripts|lib|config|instructions|templates|saytask|agents)/[A-Za-z0-9_./-]+' || true)
	done <<<"$src_list"

	if [ "$n_ref" -lt "$REF_MIN" ]; then
		echo "[UNDETERMINED] 参照が $n_ref 件 (下限 $REF_MIN) = 参照抽出が壊れて何も見ておらぬ疑い"
		return 2
	fi

	# ★何本 (file) と 何件 (参照出現) を分けて数える★ — cmd_1367 N2 是正。
	#   ★総和の検算は【参照出現】で行う★ = 内訳は参照を分類した物ゆえ、file 数と足しても合わぬ。
	local bad_files n_bad_files
	bad_files="$(printf '%s' "$findings" | cut -f1 | grep -v '^$' | sort -u)"
	n_bad_files="$(printf '%s' "$bad_files" | grep -c . || true)"

	# ★総和と内訳を同じ出力に並べ、足して合うかを機械で検算する★ (cmd_1358 の全軍規律)
	echo "[gate_undistributed] 走査元=$n_src 本 / 参照 総和=$n_ref"
	echo "  内訳 OK=$n_ok  生成物=$n_gen  ★UNDISTRIBUTED=${n_bad_files}本(参照${n_bad}件)★  MISSING(対象外)=$n_missing"
	if [ "$n_ref" -ne $((n_ok + n_gen + n_bad + n_missing)) ]; then
		echo "[UNDETERMINED] 検算 FAIL: 総和 != 内訳の和 = この出力を信じるな"
		return 2
	fi
	echo "  検算 OK (総和 == 内訳の和・参照出現で照合)"
	gate_scope_notice

	if [ "$n_bad" -gt 0 ]; then
		# ★1 道具につき 1 行★ = 呼ぶ者は同じ行へ畳む (所見が重複で膨れ、
		#   後段 (gate_nightly の head) で他の道具を押し出すのを防ぐ — 軍師一号 N1)。
		local p callers
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			# ★呼ぶ者も重複を畳む★ = 同じ script が同じ道具を3回呼んでおれば
			#   「f1.sh f1.sh f1.sh」と3度並び、畳んだ文面の枠を無駄に食う (N1 の同族)。
			callers="$(printf '%s' "$findings" | awk -F'\t' -v r="$p" '$1==r{print $2}' | sort -u | awk '{printf "%s ", $0}')"
			echo "  [UNDISTRIBUTED] ${p}  ← 追跡下の ${callers}が名指し"
		done <<<"$bad_files"
		echo "[FAIL] 配られておらぬ道具が ${n_bad_files} 本 (参照 ${n_bad} 件) = 呼ぶ者は fresh clone へ配られるが呼ばれる者は配られぬ"
		echo "  処方: .gitignore の whitelist へ否定規則を足すか、真に配るべきでなければ呼ぶ側を直せ"
		return 1
	fi
	[ "$allow_bad" -ne 0 ] && return 1
	echo "[PASS] 配線されておる道具は全て HEAD に在る"
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

	unset GATE_ALLOW_OVERRIDE

	echo "── selftest 結果: PASS=$pass NG=$fail ──"
	[ "$fail" -eq 0 ] || return 1
	return 0
}

case "${1:-}" in
	--selftest) selftest; exit $? ;;
	*) run_gate "$SCRIPT_DIR"; exit $? ;;
esac
