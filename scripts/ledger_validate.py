#!/usr/bin/env python3
"""ledger_validate.py — cmd_1255 台帳(shogun_to_karo.yaml) parse自己検証。

軍師一号設計正本 plans/cmd_1255_ledger_parse_gate_design.md §(d)/§5 準拠。
yaml.safe_load + 軽schema検証を行い、PASS=exit 0 / FAIL=exit 1(理由をstderr)。

用途は二つ:
  1) ledger_guard.sh(常駐watcher)から書込後検証として呼ばれる。
  2) 手動検証CLIとして単体実行可 (watcher死亡時の手当て・任意の台帳版検証)。

schema(設計§(d)の「軽schema」):
  - top-level が mapping(dict)であること
  - 'commands'(または後方互換 'queue')キーが存在し list であること
  - 件数 > 0 であること (★空dict/空file上書き事故を safe_load 単体では通ってしまうため schema でcatch★)
  - 各 entry が mapping かつ 識別子 ('id' または legacy 'cmd_id') を持つこと

★schema 緩和の根拠 (cmd_1255 足軽4号の実台帳照合)★:
  実台帳 queue/shogun_to_karo.yaml には 'id' でなく 'cmd_id' を使う progress_update 系
  legacy entry が 18 件実在する (index 28-45)。'id' 必須にすると **正常な編集でも FAIL 判定
  となり rollback が正しい編集を破壊** する = gate の目的(破損検知)と真逆の事故になる。
  ゆえ識別子は 'id' OR 'cmd_id' を許容する。gate の一次防衛 = parse 成功(半角コロン事故の
  検知)は不変であり、この緩和は誤検知(false rollback)を防ぐための必須調整。

Usage: ledger_validate.py <ledger.yaml>
"""
import sys

import yaml


def validate(path):
    """台帳を検証。問題があれば説明文字列を返し、正常なら None を返す。"""
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if data is None:
        return "empty file or null document (空file/空dict上書き事故の疑い)"
    if not isinstance(data, dict):
        return f"top-level is {type(data).__name__}, expected mapping"

    key = "commands" if "commands" in data else ("queue" if "queue" in data else None)
    if key is None:
        return "missing 'commands' (or legacy 'queue') key"

    cmds = data.get(key)
    if not isinstance(cmds, list):
        return f"'{key}' is not a list (got {type(cmds).__name__})"
    if len(cmds) == 0:
        return f"'{key}' is empty — possible accidental overwrite"

    for i, cmd in enumerate(cmds):
        if not isinstance(cmd, dict):
            return f"{key}[{i}] is not a mapping (got {type(cmd).__name__})"
        # 識別子は 'id'(command entry) または legacy 'cmd_id'(progress_update entry) を許容
        if cmd.get("id") is None and cmd.get("cmd_id") is None:
            return f"{key}[{i}] missing identifier ('id' or 'cmd_id')"

    return None


def main():
    if len(sys.argv) < 2:
        print("Usage: ledger_validate.py <ledger.yaml>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        err = validate(path)
    except FileNotFoundError:
        print(f"FAIL: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        # ★事故本体=自由文の半角コロン+空白による mapping 誤認等の parse 失敗★
        detail = str(e).replace("\n", " ")
        print(f"FAIL: YAML parse error: {detail}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"FAIL: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(1)

    if err:
        print(f"FAIL: schema: {err}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
