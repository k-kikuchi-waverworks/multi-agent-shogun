#!/usr/bin/env bash
# gate_artifact_capture.sh — gate-1: commit漏れの沈黙を塞ぐ (cmd_1352)
#
# 何を守るか:
#   「意図した成果物が本当に git 管理下に入ったか」を manifest 宣言と git の実体で突合する。
#   .gitignore は沈黙する: `git add dir/` は ignore された file を【警告なしに】弾き、
#   commit は成功したように見え、fresh clone で初めて欠損が露見する (最悪の遅延露見)。
#   実例 = cmd_1349: .gitignore:34 「models/」が vendoring 本体 (+575行) を黙って弾いた。
#   件数 gate が偶然捕まえたゆえ事故にならなんだ。本 gate はその偶然を契約に変える。
#   経緯の詳細: docs/content/ops/cmd_1352_silent_pitfall_gates.md
#
# 二つの mode (見る「正」が違う):
#   index mode (既定)     … git index (ls-files) を正とする。commit しようとしている中身の検分
#                           = pre-commit hook 用。
#   head mode (--committed) … ★HEAD の commit済blob を正とする = fresh clone が受け取る中身★。
#                           作業ツリーを信ぜぬ (軍師二号が cmd_1349 QC で示した流儀:
#                           作業ツリーから読めば「自分で自分を検める」循環になる)。
#                           = 夜間 cron 用。disk に在って HEAD に無い file は [NOT-IN-HEAD]。
#
# manifest 文法 (1行1宣言・# はコメント):
#   path/to/file            … この file が git 管理下に在ること
#   dir/path/               … dir 配下の全 file が git 管理下に在ること (末尾 / が dir 宣言)
#   dir/path/ min=N         … 加えて捕捉件数が N 以上 (件数 gate = cmd_1349 で効いた実物の一般化)
#
# 使い方:
#   bash scripts/gate_artifact_capture.sh <manifest>            # 単一 manifest (index mode)
#   bash scripts/gate_artifact_capture.sh --all                 # 登録済み全 manifest (index mode)
#   bash scripts/gate_artifact_capture.sh --all --committed     # 同・HEAD blob を正とする
#   bash scripts/gate_artifact_capture.sh --selftest            # 変異試験つき自己検分
#
# 三値 (0件/未判定を緑にせぬ — cmd_1342 Phase1d の流儀):
#   exit 0 = PASS / exit 1 = FAIL / exit 2 = UNDETERMINED (前提不成立・0件宣言)
set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

# CONTRACT: 空 manifest / manifest 0件 は PASS ではない (0件を緑にするな)
EMPTY_UNDETERMINED_EXIT=2

# MODE: index (既定) / head (--committed)
MODE="index"

# ─────────────────────────────────────────────────────────────────────────────
# mode 別の「捕捉されておるか」述語と一覧
# ─────────────────────────────────────────────────────────────────────────────
is_captured() { # $1=repo $2=relpath
    if [ "$MODE" = "head" ]; then
        git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null
    else
        git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
    fi
}

list_captured() { # $1=repo $2=reldir
    if [ "$MODE" = "head" ]; then
        git -C "$1" ls-tree -r --name-only HEAD -- "$2" 2>/dev/null
    else
        git -C "$1" ls-files -- "$2"
    fi
}

# 未捕捉 file の理由を分類する。★ignore 判定は check-ignore -q の exit code が正★
# (-v の出力有無で判ずるのは誤り: -v は【否定規則の match も出力する】ため、
#  whitelist 型 .gitignore で un-ignore された file を [IGNORED] と偽陽性にする。
#  本 repo の実 .gitignore (`*` + `!path` 方式) で 2026-07-26 に実測した罠である)
classify_uncaptured() { # $1=repo $2=relpath → 1行を stdout
    local repo="$1" rel="$2" culprit
    if git -C "$repo" check-ignore -q -- "$rel" 2>/dev/null; then
        culprit="$(git -C "$repo" check-ignore -v -- "$rel" 2>/dev/null | head -1 | awk -F'\t' '{print $1}')"
        echo "  [IGNORED] $rel ← ${culprit:-ignore規則} が黙って弾いておる"
    elif [ "$MODE" = "head" ]; then
        echo "  [NOT-IN-HEAD] $rel … disk に在るが HEAD に commit されておらぬ (fresh clone には渡らぬ)"
    else
        echo "  [UNTRACKED] $rel … disk に在るが一度も git add されておらぬ"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 単一 manifest の検分。stdout へ所見・戻り値 0/1/2。
# $1=manifest path (head mode では内容も HEAD blob から読む = 循環を断つ)
# ─────────────────────────────────────────────────────────────────────────────
check_manifest() {
    local manifest="$1"
    local mdir repo mrel content
    mdir="$(cd "$(dirname "$manifest")" 2>/dev/null && pwd)" || {
        echo "[gate-1] UNDETERMINED: manifest の置き場が無い: $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    }
    repo="$(git -C "$mdir" rev-parse --show-toplevel 2>/dev/null)" || {
        echo "[gate-1] UNDETERMINED: git repo の外にある manifest: $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    }
    if [ "$MODE" = "head" ]; then
        if ! git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1; then
            echo "[gate-1] UNDETERMINED: HEAD が無い (commit 0 の repo): $repo"
            return "$EMPTY_UNDETERMINED_EXIT"
        fi
        mrel="$(cd "$mdir" && git rev-parse --show-prefix)$(basename "$manifest")"
        content="$(git -C "$repo" show "HEAD:$mrel" 2>/dev/null)" || {
            echo "[gate-1] UNDETERMINED: manifest が HEAD に無い (commit されておらぬ): $mrel"
            return "$EMPTY_UNDETERMINED_EXIT"
        }
    else
        if [ ! -f "$manifest" ]; then
            echo "[gate-1] UNDETERMINED: manifest が無い: $manifest"
            return "$EMPTY_UNDETERMINED_EXIT"
        fi
        content="$(cat "$manifest")"
    fi

    local problems=0 entries=0 line raw path minspec min
    local out=""
    while IFS= read -r raw || [ -n "$raw" ]; do
        line="${raw%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        entries=$((entries + 1))
        path="${line%% *}"
        minspec="${line#"$path"}"
        min=1
        if echo "$minspec" | grep -q 'min='; then
            min="$(echo "$minspec" | sed -n 's/.*min=\([0-9][0-9]*\).*/\1/p')"
            [ -z "$min" ] && min=1
        fi

        if [ "${path%/}" != "$path" ]; then
            # ── dir 宣言 ─────────────────────────────────────────────
            local d="${path%/}"
            local diskfiles captured_n f rel
            diskfiles=""
            if [ -d "$repo/$d" ]; then
                diskfiles="$(cd "$repo" && find "$d" -name __pycache__ -prune -o -type f ! -name '*.pyc' -print | sort)"
            fi
            captured_n="$(list_captured "$repo" "$d" | grep -c . || true)"
            if [ -z "$diskfiles" ] && [ "$captured_n" -eq 0 ]; then
                out+="  [EMPTY-DIR] $d … 宣言された dir に file が 1 つも無い (真空=成果物不在)"$'\n'
                problems=$((problems + 1))
                continue
            fi
            # disk に在って捕捉されておらぬ file (= `git add dir/` の黙殺 / commit 漏れ)
            if [ -n "$diskfiles" ]; then
                while IFS= read -r rel; do
                    if ! is_captured "$repo" "$rel"; then
                        out+="$(classify_uncaptured "$repo" "$rel")"$'\n'
                        problems=$((problems + 1))
                    fi
                done <<< "$diskfiles"
            fi
            if [ "$captured_n" -lt "$min" ]; then
                out+="  [COUNT] $d … 捕捉 ${captured_n} 件 < 宣言 min=${min} (件数 gate)"$'\n'
                problems=$((problems + 1))
            fi
        else
            # ── file 宣言 ────────────────────────────────────────────
            if is_captured "$repo" "$path"; then
                :
            elif [ -e "$repo/$path" ]; then
                out+="$(classify_uncaptured "$repo" "$path")"$'\n'
                problems=$((problems + 1))
            else
                out+="  [MISSING] $path … disk にも git にも無い"$'\n'
                problems=$((problems + 1))
            fi
        fi
    done <<< "$content"

    local modenote=""
    [ "$MODE" = "head" ] && modenote=" [committed=HEAD正]"
    if [ "$entries" -eq 0 ]; then
        echo "[gate-1] UNDETERMINED: manifest に宣言が 0 件 (0件は PASS ではない): $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    fi
    if [ "$problems" -gt 0 ]; then
        echo "[gate-1] FAIL: $(basename "$manifest")${modenote} … 宣言 ${entries} 件中 問題 ${problems} 件"
        printf '%s' "$out"
        echo "  処方: [IGNORED] は (a) .gitignore へ否定規則 (!path) を足す か (b) git add -f で明示追加。"
        echo "        [UNTRACKED]/[NOT-IN-HEAD]/[MISSING] は成果物の実在と add/commit を確かめよ。直したら本 gate を再走して緑を確認せよ。"
        return 1
    fi
    echo "[gate-1] PASS: $(basename "$manifest")${modenote} … 宣言 ${entries} 件すべて捕捉済 (repo=$repo)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# --all: config/artifact_manifests/*.manifest 全件。worst-of で集約。
# head mode では manifest の一覧も HEAD tree から取る (disk のみの manifest は
# cmd_1352_gates.manifest の dir 宣言が [NOT-IN-HEAD] として別途捕まえる)。
# ─────────────────────────────────────────────────────────────────────────────
check_all() {
    local mdir="$SCRIPT_DIR/config/artifact_manifests"
    local worst=0 rc m found=0
    if [ "$MODE" = "head" ]; then
        local rels
        rels="$(git -C "$SCRIPT_DIR" ls-tree -r --name-only HEAD -- config/artifact_manifests/ 2>/dev/null | grep '\.manifest$' || true)"
        if [ -z "$rels" ]; then
            echo "[gate-1] UNDETERMINED: HEAD に manifest が 1 つも無い (0件は PASS ではない)"
            return "$EMPTY_UNDETERMINED_EXIT"
        fi
        while IFS= read -r m; do
            found=$((found + 1))
            check_manifest "$SCRIPT_DIR/$m"; rc=$?
            if [ "$rc" -eq 1 ]; then worst=1
            elif [ "$rc" -eq 2 ] && [ "$worst" -ne 1 ]; then worst=2; fi
        done <<< "$rels"
        return "$worst"
    fi
    if [ ! -d "$mdir" ]; then
        echo "[gate-1] UNDETERMINED: manifest 置き場が無い: $mdir"
        return "$EMPTY_UNDETERMINED_EXIT"
    fi
    for m in "$mdir"/*.manifest; do
        [ -e "$m" ] || continue
        found=$((found + 1))
        check_manifest "$m"; rc=$?
        if [ "$rc" -eq 1 ]; then worst=1
        elif [ "$rc" -eq 2 ] && [ "$worst" -ne 1 ]; then worst=2; fi
    done
    if [ "$found" -eq 0 ]; then
        echo "[gate-1] UNDETERMINED: manifest が 1 つも登録されておらぬ (0件は PASS ではない): $mdir"
        return "$EMPTY_UNDETERMINED_EXIT"
    fi
    return "$worst"
}

# ─────────────────────────────────────────────────────────────────────────────
# --selftest: 一時 repo を組んで故意に壊し、赤くなるべき所で赤くなるかを撃つ。
# S2 が cmd_1349 の実事故そのもの (.gitignore が dir add から黙って弾く) の再現である。
# S11-S13 が head mode (commit済blob 正 = fresh clone 視点) の検分である。
# ─────────────────────────────────────────────────────────────────────────────
selftest() {
    local T pass=0 fail=0
    T="$(mktemp -d)" || { echo "selftest: mktemp 失敗"; return 2; }
    trap 'rm -rf "$T"' RETURN

    _mkrepo() { # $1=dir
        mkdir -p "$1" && git -C "$1" init -q
    }
    _commit() { # $1=dir $2=msg
        git -C "$1" -c user.email=selftest@local -c user.name=selftest commit -q -m "$2"
    }
    _expect() { # $1=name $2=expected_rc $3=actual_rc $4=must_contain(optional) $5=output
        local name="$1" want="$2" got="$3" needle="${4:-}" output="${5:-}"
        if [ "$got" -ne "$want" ]; then
            echo "  NG $name: exit $got (期待 $want)"; fail=$((fail + 1)); return
        fi
        if [ -n "$needle" ] && ! printf '%s' "$output" | grep -qF "$needle"; then
            echo "  NG $name: 出力に「$needle」が無い"; fail=$((fail + 1)); return
        fi
        echo "  ok $name"; pass=$((pass + 1))
    }
    local r out rc

    # S1: 全て tracked → PASS
    r="$T/s1"; _mkrepo "$r"
    mkdir -p "$r/pkg"; echo a > "$r/pkg/a.py"; echo b > "$r/b.sh"
    git -C "$r" add . >/dev/null 2>&1
    printf 'b.sh\npkg/ min=1\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S1 全tracked=PASS" 0 "$rc"

    # S2: ★cmd_1349 実事故の再現★ .gitignore が dir add から黙って弾く → FAIL + 規則を名指し
    r="$T/s2"; _mkrepo "$r"
    printf 'models/\n' > "$r/.gitignore"
    mkdir -p "$r/vendor/models"; echo stream > "$r/vendor/models/stream.py"; echo keep > "$r/vendor/keep.py"
    git -C "$r" add . >/dev/null 2>&1   # ← models/ 配下は【警告なしに】弾かれる
    printf 'vendor/ min=2\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S2 ignoreの黙殺=FAIL+規則名指し" 1 "$rc" "[IGNORED]" "$out"
    _expect "S2b 弾いた.gitignore行を出力" 1 "$rc" ".gitignore:1" "$out"

    # S3: untracked (ignore ではなく add 忘れ) → FAIL [UNTRACKED]
    r="$T/s3"; _mkrepo "$r"
    echo x > "$r/x.txt"
    printf 'x.txt\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S3 add忘れ=FAIL" 1 "$rc" "[UNTRACKED]" "$out"

    # S4: disk にも無い → FAIL [MISSING]
    r="$T/s4"; _mkrepo "$r"
    printf 'ghost.txt\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S4 不在=FAIL" 1 "$rc" "[MISSING]" "$out"

    # S5: ★宣言 0 件 → UNDETERMINED (0件を緑にせぬ)★
    r="$T/s5"; _mkrepo "$r"
    printf '# コメントのみ\n\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S5 0件宣言=UNDETERMINED" 2 "$rc" "0 件" "$out"

    # S6: manifest 自体が無い → UNDETERMINED
    out="$(check_manifest "$T/nonexistent.manifest")"; rc=$?
    _expect "S6 manifest不在=UNDETERMINED" 2 "$rc"

    # S7: 件数 gate — tracked 2 件 < min=3 → FAIL [COUNT]
    r="$T/s7"; _mkrepo "$r"
    mkdir -p "$r/pkg"; echo a > "$r/pkg/a.py"; echo b > "$r/pkg/b.py"
    git -C "$r" add . >/dev/null 2>&1
    printf 'pkg/ min=3\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S7 件数gate=FAIL" 1 "$rc" "[COUNT]" "$out"

    # S8: git repo の外 → UNDETERMINED
    mkdir -p "$T/s8_norepo"
    printf 'a.txt\n' > "$T/s8_norepo/m.manifest"
    out="$(GIT_CEILING_DIRECTORIES="$T" check_manifest "$T/s8_norepo/m.manifest")"; rc=$?
    _expect "S8 repo外=UNDETERMINED" 2 "$rc"

    # S9: dir は在るが中身 0 file (真空) → FAIL
    r="$T/s9"; _mkrepo "$r"
    mkdir -p "$r/pkg"
    printf 'pkg/\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S9 真空dir=FAIL" 1 "$rc" "[EMPTY-DIR]" "$out"

    # S10: ★否定規則の偽陽性封じ★ whitelist型 gitignore (`*`+`!file`) で un-ignore された
    #      未add file は [UNTRACKED] であって [IGNORED] ではない (実repoで実測した罠)
    r="$T/s10"; _mkrepo "$r"
    printf '*\n!.gitignore\n!allowed.txt\n' > "$r/.gitignore"
    echo hello > "$r/allowed.txt"
    printf 'allowed.txt\n' > "$r/m.manifest"
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S10 否定規則match=UNTRACKED" 1 "$rc" "[UNTRACKED]" "$out"

    # ── head mode (--committed = fresh clone 視点) ──────────────────────────
    # S11: commit 済なら head mode も PASS
    r="$T/s11"; _mkrepo "$r"
    mkdir -p "$r/pkg"; echo a > "$r/pkg/a.py"
    printf 'pkg/ min=1\n' > "$r/m.manifest"
    git -C "$r" add . >/dev/null 2>&1; _commit "$r" base
    MODE="head"; out="$(check_manifest "$r/m.manifest")"; rc=$?; MODE="index"
    _expect "S11 commit済=head-PASS" 0 "$rc" "committed=HEAD正" "$out"

    # S12: ★index は緑でも HEAD に無ければ fresh clone には渡らぬ★
    #      = staged 止まりの file を head mode が [NOT-IN-HEAD] で赤にする
    echo new > "$r/pkg/new_after_commit.py"
    git -C "$r" add pkg/new_after_commit.py >/dev/null 2>&1
    out="$(check_manifest "$r/m.manifest")"; rc=$?
    _expect "S12a staged=index緑" 0 "$rc"
    MODE="head"; out="$(check_manifest "$r/m.manifest")"; rc=$?; MODE="index"
    _expect "S12b 未commit=head赤" 1 "$rc" "[NOT-IN-HEAD]" "$out"

    # S13: manifest 自体が HEAD に無い → head mode は UNDETERMINED (循環を断つ=diskの宣言を信ぜぬ)
    r="$T/s13"; _mkrepo "$r"
    echo a > "$r/a.txt"; git -C "$r" add a.txt >/dev/null 2>&1; _commit "$r" base
    printf 'a.txt\n' > "$r/m.manifest"   # ← disk にのみ在る manifest
    MODE="head"; out="$(check_manifest "$r/m.manifest")"; rc=$?; MODE="index"
    _expect "S13 manifest未commit=head-UNDETERMINED" 2 "$rc" "HEAD に無い" "$out"

    echo "----"
    if [ "$fail" -eq 0 ]; then
        echo "[gate-1 selftest] ${pass}/${pass} ALL PASS"
        return 0
    fi
    echo "[gate-1 selftest] FAIL: ok=${pass} ng=${fail}"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 引数解釈
# ─────────────────────────────────────────────────────────────────────────────
DO_ALL=0; DO_SELFTEST=0; TARGET=""
for arg in "$@"; do
    case "$arg" in
        --selftest)  DO_SELFTEST=1 ;;
        --all)       DO_ALL=1 ;;
        --committed) MODE="head" ;;
        *)           TARGET="$arg" ;;
    esac
done
if [ "$DO_SELFTEST" -eq 1 ]; then selftest; exit $?; fi
if [ "$DO_ALL" -eq 1 ]; then check_all; exit $?; fi
if [ -n "$TARGET" ]; then check_manifest "$TARGET"; exit $?; fi
echo "usage: $0 <manifest> [--committed] | --all [--committed] | --selftest"; exit 2
