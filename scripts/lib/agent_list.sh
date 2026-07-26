#!/usr/bin/env bash
# scripts/lib/agent_list.sh
# cmd_652 (2026-05-16): settings.yaml `cli.agents` 動的読込 helper (yq 不在ゆえ python3 + PyYAML 採用)
#
# 提供関数:
#   - get_active_agents          : settings.yaml の cli.agents から deprecated:true を除外したキー列挙
#   - get_active_ashigaru_agents : 上記から ashigaru* のみ抽出
#   - get_active_gunshi_agents   : 上記から gunshi* のみ抽出 (gunshi_a/b deprecated 除外)
#   - get_command_layer_agents   : shogun + karo + 全 active gunshi (ashigaru 除外)
#   - is_command_layer_agent <name> : 0=true, 1=false
#   - is_deprecated_agent <name>    : 0=true (deprecated:true 設定あり), 1=false
#   - get_agent_pane <name>      : settings.yaml の pane: field を返却 (gunshi1/2 用)、なければ空
#
# 使い方:
#   source scripts/lib/agent_list.sh
#   for agent in $(get_active_agents); do ...; done
#
# ── cmd_1405 (2026-07-27): fail-closed 化 = ★「0 件」と「読めなかった」を分ける★ ──
# 旧実装は settings.yaml 不在時に `except FileNotFoundError: sys.exit(0)` で
# ★rc=0 + 空出力★ を返した。之は「active な agent が 0 人である」と byte 単位で同一ゆえ、
# 呼び手 (watcher_supervisor) は ★誰も見張らぬまま「見張っておる」と読み、5 秒 loop を回した★。
# = 我らの木を新しい機へ写しても動かず、且つ【動かぬ】とも申さぬ形の実物。
#
# 本 helper の exit code 契約 (呼び手は之に依れ):
#   0 = 読めた (出力 0 行は ★真に 0 件★ = cli.agents が空 dict である、を意味する)
#   1 = is_deprecated mode の boolean false のみ (従前どおり)
#   2 = 呼び方が誤り (未知の mode / 引数不足)
#   3 = ★AGENT_LIST_RC_UNREADABLE = settings.yaml を読めなかった★
#       (不在 / 権限 / YAML 破断 / PyYAML 不在 / cli.agents 節そのものが無い)
#       ⇒ stderr へ `[agent_list] UNREADABLE: …` を必ず 1 行 刷る。
#   127 等 = python3 自体が無い (shell が返す。之も 0 ではない=名乗る側に倒れておる)
AGENT_LIST_RC_UNREADABLE=3

# このファイルが置かれたディレクトリの 2 階層上 = リポジトリルート
_AGENT_LIST_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# ★AGENT_LIST_SETTINGS_FILE = 試験用の縫い目 (cmd_1405)★
# 之が無い頃は「読めぬ盤面」を作るのに ★本番 config/settings.yaml を隠すしか手が無かった★=
# ★本番 supervisor を巻き込まずに fail-closed を実射できぬ★という形であった。
# 既定は従前どおり repo の config/settings.yaml ゆえ、本番の挙動は 1 も変わらぬ。
_AGENT_LIST_SETTINGS_FILE="${AGENT_LIST_SETTINGS_FILE:-${_AGENT_LIST_REPO_ROOT}/config/settings.yaml}"

_agent_list_dispatch() {
    local mode="$1"
    shift || true
    python3 - "$mode" "$@" "${_AGENT_LIST_SETTINGS_FILE}" <<'PYEOF'
import sys

RC_UNREADABLE = 3   # cmd_1405: 「読めなかった」専用 rc (0=読めた・空でありうる と分ける)


def unreadable(reason):
    # ★「0 件」ではなく「読めなかった」と名乗って落ちる★= 上位が其の場で知れること。
    sys.stderr.write(
        "[agent_list] UNREADABLE: %s ★之は【0 件】ではない = agent 一覧を読めておらぬ★ "
        "(settings=%s)\n" % (reason, settings_file)
    )
    sys.exit(RC_UNREADABLE)


argv = sys.argv[1:]
if not argv:
    sys.exit(2)
mode = argv[0]
settings_file = argv[-1]
extras = argv[1:-1]
target = extras[0] if extras else None

try:
    import yaml
except ImportError as e:
    unreadable("PyYAML を import できぬ (%s)" % e)

try:
    with open(settings_file, "r") as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    unreadable("settings.yaml が無い")
except OSError as e:
    unreadable("settings.yaml を開けぬ (%s)" % e)
except yaml.YAMLError as e:
    unreadable("settings.yaml が YAML として壊れておる (%s)" % str(e).replace("\n", " / ")[:200])

if not isinstance(data, dict):
    unreadable("settings.yaml の中身が mapping でない (空 file か構造違い: %s)" % type(data).__name__)

cli = data.get("cli")
if not isinstance(cli, dict) or "agents" not in cli:
    unreadable("cli.agents 節が無い (節ごと欠けておる = 0 件と読んではならぬ)")

agents = cli.get("agents")
if agents is None:
    agents = {}
if not isinstance(agents, dict):
    unreadable("cli.agents が mapping でない (%s)" % type(agents).__name__)

def is_deprecated(cfg):
    return bool((cfg or {}).get("deprecated", False))

def active_keys():
    return [k for k, v in agents.items() if not is_deprecated(v)]

if mode == "active":
    print("\n".join(active_keys()))
elif mode == "active_ashigaru":
    print("\n".join(k for k in active_keys() if k.startswith("ashigaru")))
elif mode == "active_gunshi":
    print("\n".join(k for k in active_keys() if k.startswith("gunshi")))
elif mode == "all_gunshi":
    # active + deprecated 全 gunshi* (cmd_645 retain 用)
    print("\n".join(k for k in agents.keys() if k.startswith("gunshi")))
elif mode == "is_deprecated":
    cfg = agents.get(target, {})
    sys.exit(0 if is_deprecated(cfg) else 1)
elif mode == "pane":
    cfg = agents.get(target, {}) or {}
    print(cfg.get("pane", ""))
else:
    sys.exit(2)
PYEOF
}

get_active_agents() {
    _agent_list_dispatch active
}

get_active_ashigaru_agents() {
    _agent_list_dispatch active_ashigaru
}

get_active_gunshi_agents() {
    _agent_list_dispatch active_gunshi
}

# active + deprecated を含む全 gunshi*。shutsujin_departure.sh の queue/inbox 初期化等で
# cmd_645 由来の deprecated agent (gunshi_a/b) も file 初期化対象に保つために使う。
# legacy 'gunshi' (settings.yaml に存在しないが backward compat retain) は呼出側で追加。
get_all_gunshi_agents() {
    _agent_list_dispatch all_gunshi
}

# shogun + karo + active gunshi (ashigaru は除外)。command-layer agent 判定用。
# cmd_1405: 旧実装は get_active_gunshi_agents を pipeline の中で呼んでおり、
# ★rc が awk の rc に食われて「読めなかった」が消えた★。先に受けて rc を通す。
get_command_layer_agents() {
    local _gunshi _rc
    _gunshi=$(get_active_gunshi_agents) || { _rc=$?; return "$_rc"; }
    {
        echo shogun
        echo karo
        printf '%s\n' "$_gunshi"
    } | awk 'NF'
}

is_command_layer_agent() {
    # 命名規約ベース判定 (settings.yaml 状態に依存しない、deprecated gunshi も command-layer 扱いで
    # watcher 抑制を維持)。新 agent class 追加時は本関数の case 文を更新せよ。
    local target="$1"
    case "$target" in
        shogun|karo) return 0 ;;
        gunshi*)     return 0 ;;  # gunshi1/gunshi2/gunshi_a/gunshi_b/gunshi (legacy) 全て command-layer
        *)           return 1 ;;
    esac
}

# rc: 0=deprecated / 1=deprecated でない / ★3=settings.yaml を読めなかった (判定不能)★
# ⇒ `if is_deprecated_agent x` と書くと 3 は「deprecated でない」に潰れる。
#    ★判定不能を区別したい呼び手は rc を数で受けよ★ (現時点で production の呼び手は無い)。
is_deprecated_agent() {
    local target="$1"
    [ -z "$target" ] && return 1
    _agent_list_dispatch is_deprecated "$target"
}

# rc: 0=読めた (pane 未設定なら空行を刷る) / 1=引数なし / ★3=settings.yaml を読めなかった★
# ⇒ ★呼び手が `set -e` 下で `x=$(get_agent_pane …)` と書くと 3 で script ごと落ちる★。
#    watcher_supervisor は之を明示的に受けておる (cmd_1405)。
get_agent_pane() {
    local target="$1"
    [ -z "$target" ] && return 1
    _agent_list_dispatch pane "$target"
}
