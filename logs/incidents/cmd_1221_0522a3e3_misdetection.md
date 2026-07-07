# Incident: cmd_1221 commit 0522a3e3 軍師2 誤検知未遂

- **日時**: 2026-07-04
- **検知者→訂正者**: gunshi2(軍師2) 自己検知・自己訂正
- **分類**: Commit Hash Verification Protocol step4「target repo確認」不履行による誤検知(false fabrication判定)
- **前例**: cmd_621 P5 07de510(fabrication判定→実在判明・logs/incidents/cmd_639_07de510_misdetection.md)と同型

## 何が起きたか

cmd_1221 MT5/MT6(ash4)のQCで、ash4報告の commit `0522a3e3`(OAUTH_SETUP.md fly.io決裁+ADR-017参照追記)を検証。
軍師2は **app repo(/home/k-kikuchi/aituber-project)+backend submodule のみ** で `git cat-file -t 0522a3e3` を実行→両方 `fatal: Not a valid object name`→**「完全fabrication」と判定**し、cmd_1221 MT5/MT6 を NEEDS_REVISION(理由①=fabricated hash)として家老へ上申した。

## 真相(誤検知)

commit `0522a3e3` は **WP theme repo(/mnt/c/Users/k-kikuchi/development/waverworks/common/wp-content/themes/waverworks-base-for-wp・origin=bitbucket)に実在**:
```
0522a3e3 docs(cmd_1221): OAUTH_SETUP Discord節へ会員bot常駐先=fly.io決裁とADR-017参照を追記
 OAUTH_SETUP.md | 2 +-
```
= OAUTH_SETUP.md(WP repo所属)の1行追記commit。ash4の「コミット0522a3e3」は**正しかった**。

## 根本原因

- **OAUTH_SETUP.md はWP repo所属**(app repoのdocs/content/SETUPではない)。軍師2は cmd_1221 の全成果物が app repo にあると暗黙前提し、target repo(WP)を確認しなかった。
- Commit Hash Verification Protocol §Prerequisite step4「target repo確認: hashのcommitが報告されたtarget repoと一致するか `git -C <repo_path> log` で確認」を**省略**。
- 発見契機: cmd_1221 GAP1(WP webhook)の証拠収集agentがWP repoで `git log origin/main..HEAD` を実行し 0522a3e3 を発見(cross-agent corroboration)。

## 影響と訂正

- 誤: cmd_1221 MT5/MT6 = NEEDS_REVISION(理由①fabricated hash)
- 正: 0522a3e3 は実在(WP repo)。ash4のcommit attribution正。**fabrication finding撤回**。
- 残る正当な観測: (a)app repo側docs(ADR-017/index.md/DISCORD_PHASE1/IMPLEMENTATION_TODO/LAUNCH_ACCEPTANCE)は未コミット(working tree)=commit推奨 (b)★ADR-017番号衝突(cmd_1221 guilds.join vs cmd_1200予約 声Two-stage)★は誤検知と無関係に有効。
- 訂正verdict: cmd_1221 MT5/MT6 = **PASS_WITH_OBSERVATIONS**(0522a3e3実在・OBS=app repo docs未コミット+ADR-017採番衝突)。家老へ訂正上申済。

## 再発防止

1. **複数repo跨ぎcmdでは各成果物のtarget repoを先に特定**してから commit検証する(cmd_1221=app repo[ADR/bot docs]+WP repo[OAUTH_SETUP]+bot config[app repo tools/])。
2. Commit Hash Protocol step4を機械的に省略しない=「該当ファイルがどのrepoにあるか」を `git -C <各repo> log --oneline | grep <hash>` で全候補repo横断確認。
3. fabrication判定の前に必ず「target repoを取り違えていないか」を自問(本incidentを規律事例として追記)。
