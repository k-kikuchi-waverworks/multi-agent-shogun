#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-011: slim_reports retention behavior
# ═══════════════════════════════════════════════════════════════
# Verifies slim_yaml.py keeps unprocessed reports for active cmds,
# archives old reports for done cmds, and preserves canonical reports.
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup_file() {
    # ルートを探す目印について（cmd_1462 で直した点）
    #
    # 以前はこの探索が scripts/slim_yaml.py を目印にしていた。
    # つまり「テスト対象そのもの」を道しるべに使っていたので、
    # 対象が消えた日に探索が失敗し、3 本とも SKIP になった（実測済み）。
    # しかも SKIP の理由は「project root が見つからない」と表示され、
    # 本当の原因（対象スクリプトが無い）を隠していた。
    # bats は SKIP を TAP の `ok` として出すので、数だけ見ると合格に見える。
    #
    # 目印をこのテストファイル自身に替えた。テストが走っている以上、必ず存在する。
    # そのうえで「対象が無い」は SKIP ではなく不合格として扱う（SKIP=FAIL の規則どおり）。
    local self_marker="tests/e2e/e2e_slim_retention.bats"

    resolve_project_root() {
        local c d abs git_root
        local -a candidates

        candidates=(
            "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
            "$BATS_TEST_DIRNAME"
            "$(dirname "$BATS_TEST_FILENAME")"
            "$BATS_TEST_FILENAME"
            "$PWD"
        )

        for c in "${candidates[@]}"; do
            [ -z "$c" ] && continue

            if [ -f "$c" ]; then
                c="$(dirname "$c")"
            fi

            for d in "$c" "$c/../.." "$c/../../.."; do
                if [ ! -d "$d" ] && [ -d "$PWD/$d" ]; then
                    d="$PWD/$d"
                fi

                abs="$(cd "$d" 2>/dev/null && pwd || true)"
                if [ -n "$abs" ] && [ -f "$abs/$self_marker" ]; then
                    printf '%s\n' "$abs"
                    return 0
                fi
            done
        done

        git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$git_root" ] && [ -f "$git_root/$self_marker" ]; then
            printf '%s\n' "$git_root"
            return 0
        fi

        return 1
    }

    if ! PROJECT_ROOT="$(resolve_project_root)"; then
        echo "リポジトリのルートが見つからない（目印: $self_marker）。" >&2
        echo "  テストの置き場所が変わった可能性がある。SKIP にはしない。" >&2
        return 1
    fi
    export PROJECT_ROOT

    if [ ! -f "$PROJECT_ROOT/scripts/slim_yaml.py" ]; then
        echo "テスト対象が無い: $PROJECT_ROOT/scripts/slim_yaml.py" >&2
        echo "  これは環境の問題ではなく、対象そのものが失われている。SKIP ではなく不合格とする。" >&2
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        echo "python3 が無いので slim_yaml.py を実行できない。" >&2
        echo "  SKIP=FAIL の規則により、走らなかったことを合格として扱わない。" >&2
        return 1
    fi
}

build_tmp_project() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/queue"/{inbox,tasks,reports,archive,reports,archive/reports}
}

run_slim_yaml() {
    local root="$1"
    local agent="$2"
    python3 "$root/scripts/slim_yaml.py" "$agent"
}

seed_yaml() {
    local file="$1" value="$2"
    printf '%s\n' "$value" > "$file"
}

@test "E2E-011-A: unprocessed report with active cmd is kept" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_retention_XXXXXX")"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: pending\n'
    seed_yaml "$root/queue/reports/ashigaru1_cmd_test_report.yaml" $'parent_cmd: cmd_test\nstatus: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_ignored\nstatus: done\n'

    touch -d "2 days ago" "$root/queue/reports/ashigaru1_cmd_test_report.yaml"
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Active parent_cmd means this report is kept.
    [ -f "$root/queue/reports/ashigaru1_cmd_test_report.yaml" ]
    # Canonical report is always preserved.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]

    rm -rf "$root"
}

@test "E2E-011-B: old report for done cmd is archived" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_retention_XXXXXX")"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_cmd_test_report.yaml" $'parent_cmd: cmd_test\nstatus: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_ignored\nstatus: done\n'

    touch -d "2 days ago" "$root/queue/reports/ashigaru1_cmd_test_report.yaml"
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Non-canonical report is archived.
    [ ! -f "$root/queue/reports/ashigaru1_cmd_test_report.yaml" ]
    [ -f "$root/queue/archive/reports/ashigaru1_cmd_test_report.yaml" ]
    # Canonical report remains.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]

    rm -rf "$root"
}

@test "E2E-011-C: canonical report remains even if old and complete" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_retention_XXXXXX")"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_done\nstatus: done\n'
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Canonical report is always retained.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]

    rm -rf "$root"
}
