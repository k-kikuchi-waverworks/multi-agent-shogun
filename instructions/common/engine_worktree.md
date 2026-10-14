# engine の作業木は scripts/worktree.sh で作る（cmd_2059・家老が engine の task に添える文）

engine を直す時は、本番の木を触らず作業木で作業する。手順の紙は engine の `docs/WORKTREE.md`。
1. 作る: `bash scripts/worktree.sh add <名前> <枝の名>` → `C:\tools\<名前>`。手で `git worktree add` しない（WSL の git で作ると試験が3本落ちる）。
2. 作業木の git は Windows の git で撃つ: `cd /mnt/c/tools && cmd.exe /c "cd /d C:\tools\<名前> && git ..."`。
3. 作業木で `npm` を撃たない（node_modules は本番への junction）。試験は `node.exe node_modules/vitest/vitest.mjs run`。
4. commit は通常の pre-commit を通す。`--no-verify` は使わない。落ちたら家老に伺う。
5. push は Windows の git で（WSL の git は credential manager が落ちる）。push したら枝の名を家老へ。
6. 消す: `bash scripts/worktree.sh remove <名前>`。作業木を手で `rm -rf` しない（本番の node_modules まで消えうる）。
