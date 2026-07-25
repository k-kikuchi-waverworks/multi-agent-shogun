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
# manifest 文法 (1行1宣言・# はコメント):
#   path/to/file            … この file が git 管理下に在ること
#   dir/path/               … dir 配下の全 file が git 管理下に在ること (末尾 / が dir 宣言)
#   dir/path/ min=N         … 加えて tracked 件数が N 以上 (件数 gate = cmd_1349 で効いた実物の一般化)
#
# 使い方:
#   bash scripts/gate_artifact_capture.sh <manifest>   # 単一 manifest を検分
#   bash scripts/gate_artifact_capture.sh --all        # config/artifact_manifests/*.manifest 全件
#   bash scripts/gate_artifact_capture.sh --selftest   # 変異試験つき自己検分 (一時repoを作って故意に壊す)
#
# 三値 (0件/未判定を緑にせぬ — cmd_1342 Phase1d の流儀):
#   exit 0 = PASS / exit 1 = FAIL / exit 2 = UNDETERMINED (前提不成立・0件宣言)
set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

# CONTRACT: 空 manifest / manifest 0件 は PASS ではない (0件を緑にするな)
EMPTY_UNDETERMINED_EXIT=2

# untracked file の理由を分類する。★ignore 判定は check-ignore -q の exit code が正★
# (-v の出力有無で判ずるのは誤り: -v は【否定規則の match も出力する】ため、
#  whitelist 型 .gitignore で un-ignore された file を [IGNORED] と偽陽性にする。
#  本 repo の実 .gitignore (`*` + `!path` 方式) で 2026-07-26 に実測した罠である)
classify_untracked() { # $1=repo $2=relpath → 1行を stdout
    local repo="$1" rel="$2" culprit
    if git -C "$repo" check-ignore -q -- "$rel" 2>/dev/null; then
        culprit="$(git -C "$repo" check-ignore -v -- "$rel" 2>/dev/null | head -1 | awk -F'\t' '{print $1}')"
        echo "  [IGNORED] $rel ← ${culprit:-ignore規則} が黙って弾いておる"
    else
        echo "  [UNTRACKED] $rel … disk に在るが一度も git add されておらぬ"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 単一 manifest の検分。stdout へ所見・戻り値 0/1/2。
# $1=manifest path
# ─────────────────────────────────────────────────────────────────────────────
check_manifest() {
    local manifest="$1"
    if [ ! -f "$manifest" ]; then
        echo "[gate-1] UNDETERMINED: manifest が無い: $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    fi
    local mdir repo
    mdir="$(cd "$(dirname "$manifest")" && pwd)"
    repo="$(git -C "$mdir" rev-parse --show-toplevel 2>/dev/null)" || {
        echo "[gate-1] UNDETERMINED: git repo の外にある manifest: $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    }

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
            if [ ! -d "$repo/$d" ]; then
                out+="  [MISSING-DIR] $d … 宣言された dir が disk に無い"$'\n'
                problems=$((problems + 1))
                continue
            fi
            local diskfiles tracked_n f rel
            diskfiles="$(cd "$repo" && find "$d" -name __pycache__ -prune -o -type f ! -name '*.pyc' -print | sort)"
            if [ -z "$diskfiles" ]; then
                out+="  [EMPTY-DIR] $d … 宣言された dir に file が 1 つも無い (真空=成果物不在)"$'\n'
                problems=$((problems + 1))
                continue
            fi
            while IFS= read -r rel; do
                if ! git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
                    out+="$(classify_untracked "$repo" "$rel")"$'\n'
                    problems=$((problems + 1))
                fi
            done <<< "$diskfiles"
            tracked_n="$(git -C "$repo" ls-files -- "$d" | wc -l)"
            if [ "$tracked_n" -lt "$min" ]; then
                out+="  [COUNT] $d … tracked ${tracked_n} 件 < 宣言 min=${min} (件数 gate)"$'\n'
                problems=$((problems + 1))
            fi
        else
            # ── file 宣言 ────────────────────────────────────────────
            if git -C "$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
                :
            elif [ -e "$repo/$path" ]; then
                out+="$(classify_untracked "$repo" "$path")"$'\n'
                problems=$((problems + 1))
            else
                out+="  [MISSING] $path … disk にも git にも無い"$'\n'
                problems=$((problems + 1))
            fi
        fi
    done < "$manifest"

    if [ "$entries" -eq 0 ]; then
        echo "[gate-1] UNDETERMINED: manifest に宣言が 0 件 (0件は PASS ではない): $manifest"
        return "$EMPTY_UNDETERMINED_EXIT"
    fi
    if [ "$problems" -gt 0 ]; then
        echo "[gate-1] FAIL: $(basename "$manifest") … 宣言 ${entries} 件中 問題 ${problems} 件"
        printf '%s' "$out"
        echo "  処方: [IGNORED] は (a) .gitignore へ否定規則 (!path) を足す か (b) git add -f で明示追加。"
        echo "        [UNTRACKED]/[MISSING] は成果物の実在と add を確かめよ。直したら本 gate を再走して緑を確認せよ。"
        return 1
    fi
    echo "[gate-1] PASS: $(basename "$manifest") … 宣言 ${entries} 件すべて git 管理下 (repo=$repo)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# --all: config/artifact_manifests/*.manifest 全件。worst-of で集約。
# ─────────────────────────────────────────────────────────────────────────────
check_all() {
    local mdir="$SCRIPT_DIR/config/artifact_manifests"
    local worst=0 rc m found=0
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
# ─────────────────────────────────────────────────────────────────────────────
selftest() {
    local T pass=0 fail=0
    T="$(mktemp -d)" || { echo "selftest: mktemp 失敗"; return 2; }
    trap 'rm -rf "$T"' RETURN

    _mkrepo() { # $1=dir
        mkdir -p "$1" && git -C "$1" init -q
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

    echo "----"
    if [ "$fail" -eq 0 ]; then
        echo "[gate-1 selftest] ${pass}/${pass} ALL PASS"
        return 0
    fi
    echo "[gate-1 selftest] FAIL: ok=${pass} ng=${fail}"
    return 1
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
    --all)      check_all; exit $? ;;
    "")
        echo "usage: $0 <manifest> | --all | --selftest"; exit 2 ;;
    *)          check_manifest "$1"; exit $? ;;
esac
