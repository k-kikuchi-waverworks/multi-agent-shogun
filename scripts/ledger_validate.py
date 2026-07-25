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
  - ★entry id ('id' field) が台帳内で一意であること (cmd_1341 B-N1)★
  - ★mapping 内に同名 key が無いこと — 入れ子含む全 mapping (cmd_1341 追加scope)★

★cmd_1341 硬化の根拠 (軍師二号QC 2026-07-25)★:
  (1) id一意性: 本体台帳に cmd_1302/cmd_1303 の二重登録が実在したのに validate は
      PASS を返していた = 採番gate(cmd_1333)が拠り所にする validator が、gate が防ぐ
      べき失敗モード(番号重複)そのものに盲目だった。
      ★検査対象は 'id' field のみ。legacy 'cmd_id' は progress_update 系が既存 cmd を
      【参照】する field であり、重複(cmd_640×2)や 'id' との重なり(cmd_611)が実台帳に
      正当に存在する。これらまで一意強制すると正常な台帳が FAIL → ledger_guard が
      false rollback を撃つ = 下記「schema 緩和の根拠」と同じ事故になるため除外★。
  (2) 重複key: 家老が同一entryへ karo_progress: を繰り返し追記 → YAML 後勝ちで先の
      記録が【黙って消える】のに validate は PASS していた。yaml.safe_load では
      検知不可能(load 時点で既に潰れている)ため、construct_mapping を override した
      Loader で【潰れる前】の node を検査する。

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


class DuplicateKeyError(yaml.YAMLError):
    """mapping 内の同名 key (YAML 後勝ちで情報が黙って消える) を表す。

    yaml.YAMLError 派生ゆえ main() の既存 except で FAIL 扱いになる。
    """


class UniqueKeyLoader(yaml.SafeLoader):
    """重複 key を【後勝ちで潰れる前】に検知する SafeLoader。

    safe_load は同名 key を黙って後勝ちマージするため load 後の dict からは
    検知不可能。construct_mapping で raw node の key 列を直接検査する。
    入れ子 mapping (cmd_645 の子entry等) も各 mapping 単位で検査される。
    """

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _value_node in node.value:
            key = self.construct_object(key_node, deep=True)
            try:
                is_dup = key in seen
                seen.add(key)
            except TypeError:
                # unhashable key (list等) は SafeLoader 本体が別途エラーにする
                continue
            if is_dup:
                raise DuplicateKeyError(
                    f"duplicate mapping key {key!r} (line {key_node.start_mark.line + 1}) "
                    f"— YAML後勝ちで先の値が黙って消える。一意なkey名で追記せよ"
                )
        return super().construct_mapping(node, deep=deep)


def validate(path):
    """台帳を検証。問題があれば説明文字列を返し、正常なら None を返す。"""
    with open(path, encoding="utf-8") as f:
        data = yaml.load(f, Loader=UniqueKeyLoader)

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

    seen_ids = {}
    for i, cmd in enumerate(cmds):
        if not isinstance(cmd, dict):
            return f"{key}[{i}] is not a mapping (got {type(cmd).__name__})"
        # 識別子は 'id'(command entry) または legacy 'cmd_id'(progress_update entry) を許容
        if cmd.get("id") is None and cmd.get("cmd_id") is None:
            return f"{key}[{i}] missing identifier ('id' or 'cmd_id')"
        # ★id一意性 (cmd_1341 B-N1)。'id' field のみ — legacy 'cmd_id' は参照field
        # ゆえ対象外 (cmd_640×2 / cmd_611 の id∩cmd_id 重なりが実台帳に正当に在る)★
        cid = cmd.get("id")
        if cid is not None:
            try:
                if cid in seen_ids:
                    return (
                        f"duplicate entry id {cid!r} ({key}[{seen_ids[cid]}] と {key}[{i}]) "
                        f"— 採番衝突または二重登録。scripts/cmd_id_alloc.sh --claim で改番せよ"
                    )
                seen_ids[cid] = i
            except TypeError:
                return f"{key}[{i}] id is unhashable (got {type(cid).__name__})"

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
