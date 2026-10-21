# AGENTS.md —— Agent 开发规则

适用：本仓库所有 AI agent。优先级：用户当前指令 > 本文件 > 项目其他文档；更严格的安全/评测规则始终有效。

## 五条硬性规则

1. **debug / 功能开发必须完整测试并编译 app**，把命令和结果写进 commit / PR。
2. **编译后只留一个 app**：结束旧进程，清理其他工作树的同名 app，确认 1 个 `.app` + 1 个进程。
3. **分支名规范**：`<agent>/<task-id>-<type>-<slug>`，如 `dsh/T-009-docs-shorten-handbook`。
4. **commit / PR 必须说清功能**：标题明确；正文写背景、改动、验证、影响、风险。
5. **开工前先同步最新基线**，开发中基线前进要 rebase，避免冲突。

## 开工

```bash
git fetch --all --prune
git status --short                 # 必须为空
git switch dev && git pull --ff-only   # 没有 dev 就用 main
git switch -c dsh/T-xxx-<type>-<slug> dev
```

- 记录 base commit；只改任务范围；同一文件同一时间只有一个 writer。
- 分支名能看出 agent、任务、类型；禁止 `test`、`fix`、`dev2`、`tmp`。

## 测试与编译

```bash
swift build --disable-sandbox       # 普通终端去掉 --disable-sandbox
./scripts/test.sh --disable-sandbox
git diff --check
shasum -a 256 -c eval/FROZEN.sha256 --quiet

EVAL_ASR=0 scripts/eval.sh          # Core / 触发 / 上下文
scripts/eval.sh                     # ASR / 发布前

./build.sh
codesign --verify --deep --strict --verbose=2 build/MeetingCopilot.app
```

- 构建或测试失败不算完成；不能运行的项标「未运行 / 需人工验证」。
- 纯文档改动可跳过 app 编译，但要说明。
- 功能发生较多迭代或大型迭代时，同步更新 README（特性、使用方式、限制、界面变化）。
- 正式指标只认冻结评测；扩展评测只能写“参考”。

## 单 app

```bash
pkill -f '/MeetingCopilot.app/Contents/MacOS/MeetingCopilot' 2>/dev/null || true

./build.sh

git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
  [ "$wt" = "$PWD" ] && continue
  rm -rf -- "$wt/build/MeetingCopilot.app"
done

find .. -maxdepth 4 -type d -name 'MeetingCopilot.app' -print
pgrep -fl 'MeetingCopilot.app/Contents/MacOS/MeetingCopilot' || true
```

- 期望结果：1 个 `.app`、1 个进程；不是就停下来清理。
- 版本以 `Info.plist` / `codesign` 为准；构建产物不提交。
- 不在主 clone 和开发工作树各留一个 app。

## 提交与 PR

- Commit：`<type>(<scope>): <subject>`，正文写 why / what / verify；trailer 写 `Task: T-xxx`、`Agent: dsh|claude`。
- 一个 commit 只做一件事；不提交 `build/`、`.build/`、密钥、个人信息、本机绝对路径。
- PR 标题同主 commit；正文含：功能、背景、改动、验证、影响/风险、人工验收、回滚。
- 目标分支：有 `dev` 用 `dev`，否则 `main`。不自己合并，等用户审核。
- **PR 创建或合并后，把链接发给用户。**

## 发布

- 功能 / 修复 / 版本号 / 版本历史先合入 `main`。
- 在 `main` 的 commit 上打 tag（通常是 PR 合并提交），push tag。
- 从 tag 检出干净目录构建，验证 app、`codesign`、DMG 后创建 GitHub Release。
- 不在副分支打正式 tag；RC / 预发布除外，事后必须合回 `main`。

## 红线

- 不改冻结评测、阈值、评分逻辑；有疑问写「需人工确认」。
- 不直接 push `main` / `dev`、不 force push、不改共享历史。
- 发布、签名、TCC、钥匙串需用户明确授权。
- 不保存音频 / 截图；不申请辅助功能；不提交个人信息 / 密钥 / 绝对路径。
- 不删用户数据；只清理 gitignored 构建产物。

## 完成标准

- [ ] 分支基于最新 `dev` / `main`
- [ ] 构建、测试通过；按改动类型跑评测
- [ ] app 已编译 / 签名，且只剩一个 app
- [ ] commit / PR 清晰，PR 链接已发用户
- [ ] 需人工验证项已标注

汇报：分支与 base、改动、测试结果、app 路径/版本、单 app 状态、PR 链接、待人工验收项。
