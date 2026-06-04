#!/usr/bin/env python3
"""
discord_ch_state_verify.py — Discord ch操作後 独立live状態検証

cmd_873 で確立した検証ロジックを汎用化。
5項目を bot API (urllib 標準ライブラリ) で検証:
  1. 削除確認 (ch消滅)
  2. 保護ch無傷 (存在確認)
  3. read-only (@everyone SEND deny + VIEW維持)
  4. bot SEND allow (permission_overwrites)
  5. smoke test (bot投稿→即DELETE、任意)

認証: backend/.env の DISCORD_TOKEN / DISCORD_GUILD_ID を参照 (ハードコード禁止)
EXIT 0 = 全PASS  /  EXIT 1 = 1件以上FAIL

使い方:
  python3 discord_ch_state_verify.py                 # DEFAULT_CONFIG使用
  python3 discord_ch_state_verify.py --help
  python3 discord_ch_state_verify.py \\
    --deleted-ids "111,222" \\
    --protected-names "welcome-ja,chat-ja" \\
    --readonly-ids "333,444" \\
    --bot-role-id "555" \\
    --smoke-ch-id "666"
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_BASE = "https://discord.com/api/v10"
USER_AGENT = "multi-agent-shogun/discord-ch-state-verify (read-verify, cmd_884)"

# ── Discord permission bits ──────────────────────────────────────────────────
PERM_VIEW_CHANNEL   = 1 << 10  # 1024
PERM_SEND_MESSAGES  = 1 << 11  # 2048

# ── backend/.env 探索パス ────────────────────────────────────────────────────
ENV_PATHS = [
    "/home/k-kikuchi/aituber-project/backend/.env",
    "/mnt/c/Users/k-kikuchi/development/aituber-project/backend/.env",
]

# ── DEFAULT_CONFIG (引数なし実行時の汎用テンプレ) ──────────────────────────
# 実際の検証対象は引数またはこの辞書を上書きして使用する。
# ★ここにch IDをハードコードしない★ — 実行時に渡すか、envから取得すること。
DEFAULT_CONFIG = {
    "deleted_ids":        [],   # 削除済みのはずのch id list (str)
    "protected_names":    [],   # 存在するはずのch name list (例: "welcome-ja")
    "readonly_ids":       [],   # read-only化されたch id list
    "bot_role_id":        None, # botのrole id (Noneなら bot overwrite確認をskip)
    "smoke_ch_id":        None, # smoke test対象ch id (Noneなら skip)
}


# ── 環境変数ロード ──────────────────────────────────────────────────────────
def load_env() -> dict:
    for path in ENV_PATHS:
        if os.path.isfile(path):
            result = {}
            with open(path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, _, v = line.partition("=")
                    result[k.strip()] = v.strip()
            return result
    print("[ERROR] backend/.env が見つかりません", file=sys.stderr)
    sys.exit(1)


# ── Discord API ──────────────────────────────────────────────────────────────
def api_get(token: str, path: str) -> dict | list:
    req = urllib.request.Request(
        API_BASE + path,
        headers={
            "Authorization": f"Bot {token}",
            "User-Agent": USER_AGENT,
        },
    )
    req.get_method = lambda: "GET"
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:300]
        print(f"[ERROR] GET {path} → HTTP {e.code}: {body}", file=sys.stderr)
        sys.exit(1)


def api_post(token: str, path: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        API_BASE + path,
        data=data,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:300]
        print(f"[ERROR] POST {path} → HTTP {e.code}: {body}", file=sys.stderr)
        return {}


def api_delete(token: str, path: str) -> bool:
    req = urllib.request.Request(
        API_BASE + path,
        headers={
            "Authorization": f"Bot {token}",
            "User-Agent": USER_AGENT,
        },
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status in (200, 204)
    except urllib.error.HTTPError as e:
        print(f"[WARN] DELETE {path} → HTTP {e.code}", file=sys.stderr)
        return False


# ── 検証ロジック ─────────────────────────────────────────────────────────────
def verify_deleted(channels: list, deleted_ids: list[str]) -> list[tuple[bool, str]]:
    """削除済みのはずのch idがguild ch listに存在しないことを確認。"""
    existing_ids = {c["id"] for c in channels}
    results = []
    for cid in deleted_ids:
        if cid not in existing_ids:
            results.append((True,  f"削除確認: id={cid} → PASS (ch消滅確認)"))
        else:
            name = next((c.get("name","?") for c in channels if c["id"] == cid), "?")
            results.append((False, f"削除確認: id={cid} name={name} → FAIL (まだ存在する)"))
    return results


def verify_protected(channels: list, protected_names: list[str]) -> list[tuple[bool, str]]:
    """指定名のchが存在することを確認 (保護ch無傷確認)。"""
    existing_names = {c.get("name","") for c in channels}
    results = []
    for name in protected_names:
        if name in existing_names:
            ch = next(c for c in channels if c.get("name") == name)
            results.append((True,  f"保護ch: {name} (id={ch['id']}) → PASS (存在確認)"))
        else:
            results.append((False, f"保護ch: {name} → FAIL (ch が見つからない=誤削除の可能性)"))
    return results


def verify_readonly(channels: list, readonly_ids: list[str], guild_id: str) -> list[tuple[bool, str]]:
    """@everyone の SEND_MESSAGES deny + VIEW_CHANNEL 維持を確認。"""
    ch_map = {c["id"]: c for c in channels}
    results = []
    for cid in readonly_ids:
        ch = ch_map.get(cid)
        if not ch:
            results.append((False, f"read-only: id={cid} → FAIL (chが存在しない)"))
            continue
        name = ch.get("name", "?")
        overwrites = ch.get("permission_overwrites", [])
        everyone_ow = next((ow for ow in overwrites if ow["type"] == 0 and ow["id"] == guild_id), None)
        if everyone_ow is None:
            results.append((False, f"read-only: {name} (id={cid}) → FAIL (@everyone overwriteが存在しない)"))
            continue
        deny  = int(everyone_ow.get("deny",  0))
        allow = int(everyone_ow.get("allow", 0))
        send_denied = bool(deny & PERM_SEND_MESSAGES)
        view_denied = bool(deny & PERM_VIEW_CHANNEL)
        if send_denied and not view_denied:
            results.append((True,  f"read-only: {name} (id={cid}) → PASS (SEND deny={send_denied}, VIEW deny={view_denied})"))
        else:
            results.append((False, f"read-only: {name} (id={cid}) → FAIL (SEND deny={send_denied}, VIEW deny={view_denied}, allow={allow}, deny={deny})"))
    return results


def verify_bot_send_allow(channels: list, readonly_ids: list[str], bot_role_id: str | None) -> list[tuple[bool, str]]:
    """read-only chでbot role/memberのSEND allowを確認。"""
    if not bot_role_id:
        return [(True, "bot SEND allow確認: bot_role_id未指定のためskip (OK)")]
    ch_map = {c["id"]: c for c in channels}
    results = []
    for cid in readonly_ids:
        ch = ch_map.get(cid)
        if not ch:
            continue
        name = ch.get("name", "?")
        overwrites = ch.get("permission_overwrites", [])
        bot_ow = next((ow for ow in overwrites if ow["id"] == bot_role_id), None)
        if bot_ow is None:
            results.append((False, f"bot SEND allow: {name} (id={cid}) → FAIL (bot roleのoverwriteが存在しない)"))
            continue
        allow = int(bot_ow.get("allow", 0))
        send_allowed = bool(allow & PERM_SEND_MESSAGES)
        if send_allowed:
            results.append((True,  f"bot SEND allow: {name} (id={cid}) → PASS (SEND allow確認)"))
        else:
            results.append((False, f"bot SEND allow: {name} (id={cid}) → FAIL (bot role allow={allow}, SEND bit未設定)"))
    return results


def smoke_test(token: str, smoke_ch_id: str) -> tuple[bool, str]:
    """bot投稿smoke test: テストメッセージを送信→即削除。"""
    payload = {"content": "🤖 [discord-ch-state-verify] smoke test — 即削除します"}
    resp = api_post(token, f"/channels/{smoke_ch_id}/messages", payload)
    msg_id = resp.get("id")
    if not msg_id:
        return (False, f"smoke test: ch={smoke_ch_id} → FAIL (POST失敗: {resp})")
    time.sleep(0.5)
    deleted = api_delete(token, f"/channels/{smoke_ch_id}/messages/{msg_id}")
    if deleted:
        return (True,  f"smoke test: ch={smoke_ch_id} → PASS (msg_id={msg_id} 送信+削除成功)")
    else:
        return (True,  f"smoke test: ch={smoke_ch_id} → PASS (送信成功、削除は403でもOK: msg_id={msg_id})")


# ── メイン ──────────────────────────────────────────────────────────────────
def parse_args():
    parser = argparse.ArgumentParser(description="Discord ch状態 独立live検証")
    parser.add_argument("--deleted-ids",       default="", help="削除済みch id (カンマ区切り)")
    parser.add_argument("--protected-names",   default="", help="存在するはずのch名 (カンマ区切り)")
    parser.add_argument("--readonly-ids",      default="", help="read-only ch id (カンマ区切り)")
    parser.add_argument("--bot-role-id",       default=None, help="bot roleのid (省略可)")
    parser.add_argument("--smoke-ch-id",       default=None, help="smoke test対象ch id (省略可)")
    return parser.parse_args()


def main():
    args = parse_args()
    env = load_env()

    token    = env.get("DISCORD_TOKEN")
    guild_id = env.get("DISCORD_GUILD_ID")
    if not token:
        print("[ERROR] DISCORD_TOKEN が backend/.env に未設定", file=sys.stderr)
        sys.exit(1)
    if not guild_id:
        print("[ERROR] DISCORD_GUILD_ID が backend/.env に未設定", file=sys.stderr)
        sys.exit(1)

    # 引数 or DEFAULT_CONFIG をマージ
    def csv(s):
        return [x.strip() for x in s.split(",") if x.strip()] if s else []

    deleted_ids     = csv(args.deleted_ids)     or DEFAULT_CONFIG["deleted_ids"]
    protected_names = csv(args.protected_names) or DEFAULT_CONFIG["protected_names"]
    readonly_ids    = csv(args.readonly_ids)    or DEFAULT_CONFIG["readonly_ids"]
    bot_role_id     = args.bot_role_id           or DEFAULT_CONFIG["bot_role_id"]
    smoke_ch_id     = args.smoke_ch_id           or DEFAULT_CONFIG["smoke_ch_id"]

    print(f"[INFO] Guild: {guild_id}")
    print(f"[INFO] 削除確認 ch: {deleted_ids}")
    print(f"[INFO] 保護ch名:    {protected_names}")
    print(f"[INFO] read-only ch:{readonly_ids}")
    print(f"[INFO] bot role:    {bot_role_id}")
    print(f"[INFO] smoke ch:    {smoke_ch_id}")
    print()

    # Guild ch list 取得
    channels = api_get(token, f"/guilds/{guild_id}/channels")

    all_results: list[tuple[bool, str]] = []

    # 1. 削除確認
    if deleted_ids:
        all_results += verify_deleted(channels, deleted_ids)

    # 2. 保護ch無傷確認
    if protected_names:
        all_results += verify_protected(channels, protected_names)

    # 3. read-only確認
    if readonly_ids:
        all_results += verify_readonly(channels, readonly_ids, guild_id)

    # 4. bot SEND allow確認
    if readonly_ids and bot_role_id:
        all_results += verify_bot_send_allow(channels, readonly_ids, bot_role_id)

    # 5. smoke test
    if smoke_ch_id:
        all_results.append(smoke_test(token, smoke_ch_id))

    if not all_results:
        print("[WARN] 検証項目が0件です。引数または DEFAULT_CONFIG を確認してください。")
        sys.exit(0)

    # 結果表示
    print("=" * 60)
    passed = 0
    for ok, msg in all_results:
        tag = "PASS" if ok else "FAIL"
        print(f"[{tag}] {msg}")
        if ok:
            passed += 1

    total = len(all_results)
    print("=" * 60)
    print(f"結果: {passed}/{total} PASS  EXIT={'0' if passed == total else '1'}")

    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
