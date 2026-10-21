# AGENTS.md —— 公共 Agent 开发手册

版本：2026-10-21　｜　适用：本仓库所有 AI 协作者（Claude Code、DeepSeek Harness、后续接入的 agent）以及人类开发者。

这份手册规定 agent 在本仓库中**怎么开工、怎么测试、怎么编译、怎么提交、怎么提 PR**。
目标只有三个：**不把坏代码合进去、不留下多个混淆版本、不让别人替你收拾工作区。**

> 如果本手册与项目内其他文档冲突：以**用户当前明确指令**为准；其次是本手册；项目文档中**更严格的安全/评测规则**始终有效。
> 开工前如果发现规则冲突，先停下来问用户，不要自行选一个。

---

## 0. 五条硬性规则（先记住这五条）

1. **进行 debug / 功能开发时，必须自行完成完整测试和编译。**
   不能只改代码就说“完成了”；必须构建通过、测试通过、需要时编译出 app，并把命令和结果写进提交/PR。
2. **编译完成后只保留一个 app，不允许留下多个版本。**
   构建前结束旧实例；构建后删除其他工作树/目录里的同名 app；启动前确认只有一个 `.app`、一个进程。绝不能凭图标猜版本。
3. **分支命名必须规范，能一眼看出是谁、做什么任务。**
   统一 `<agent>/<task-id>-<type>-<slug>`，例如 `dsh/T-007-docs-agent-handbook`、`claude/T-001-fix-iss014-provider-profiles`。
4. **commit 和 PR 必须清晰表达当前改动。**
   标题说清功能；正文写清为什么、改了什么、怎么验证、影响和风险；不要用“update”“fix bug”“misc”这类无法追踪的表述。
5. **开发前必须拉取最新仓库状态并确认基线，防止重复冲突。**
   `fetch` → 检查工作区 → 从最新 `dev`（没有则 `main`）开分支 → 记录 base commit；开发期间基线前进要 rebase 并重跑验证。

---

## 1. 角色与原则

| 角色 | 职责 |
|---|---|
| 用户 / 产品负责人 | 决定产品行为、阈值、是否重新冻结、是否发布；最终验收和合并 |
| 实现 agent | 同步基线、实现、自测、编译、写 commit/PR、响应评审 |
| 评审 agent（可选） | 只读审查 diff、复跑验证、指出风险；不直接改作者分支 |
| 集成者 | 合并 PR、更新项目状态文档、发布；通常是用户或用户指定的人 |

原则：

- **仓库是共享记忆**：两个 agent 不共享对话，约定、证据、状态都写进文件。
- **一个任务一个 owner**：同一时间同一个文件只有一个 writer。
- **没有证据不算完成**：命令、输出、app 路径、版本、进程数都要能复现。
- **用户是最终权威**：产品行为、评测阈值、发布、合并由用户决定；agent 不自行合并。
- **小步提交**：一个 PR 只做一件事，不夹带无关重构或格式化。

---

## 2. 开工前：同步、确认、开分支

### 2.1 每次开工前必须执行

```bash
git fetch --all --prune
git status --short          # 必须为空；有未提交改动先处理，不要带着别人的改动开工
git worktree list           # 确认自己不在别人的工作树里开发
git switch dev              # 没有 dev 就用 main
git pull --ff-only          # 本地/远端不同步时先对齐
git log --oneline -5        # 确认基线
```

- 记录本次 base：`git rev-parse --short HEAD`。
- 如果 `dev`/`main` 在开发期间前进：`git rebase dev`（或 `origin/dev`），解决冲突后**重跑全部验证**。
- 不要基于旧分支继续开发；不要用 `git reset --hard` 处理别人的提交。
- 远端没有 `dev` 时用 `main`；不要擅自创建/推送 `dev`，除非用户确认。

### 2.2 分支命名

统一格式：

```text
<agent>/<task-id>-<type>-<slug>
```

| 部分 | 说明 | 示例 |
|---|---|---|
| `<agent>` | `dsh` / `claude` / `user` | `dsh` |
| `<task-id>` | 看板/issue 编号 | `T-007` |
| `<type>` | `feat` / `fix` / `docs` / `test` / `refactor` / `chore` / `perf` | `docs` |
| `<slug>` | 2–5 个英文单词，kebab-case，表达功能 | `agent-handbook` |

好例子：

```text
dsh/T-007-docs-agent-handbook
dsh/T-006-fix-composer-multiline
claude/T-001-fix-iss014-provider-profiles
user/T-010-feat-per-preset-screenshot
```

坏例子（禁止）：

```text
dev2
test
fix
tmp
new-branch
my-work
```

规则：

- 从最新 `dev`/`main` 开分支，不从别的任务分支开。
- 一个任务一个分支；不同任务不要复用同一分支。
- 不直接提交 `dev`/`main`；不 force push；不改写共享历史。
- 局部 fixup 提交可以在 PR 前 squash；但已经推送、别人在用的分支不要改写。
- 紧急修复用 `hotfix/<task-id>-<slug>`，并先取得用户同意。

### 2.3 认领与文件范围

- 有看板/任务系统时，先认领任务，写清 owner、分支、**文件范围**、依赖。
- 文件范围与别人重叠时：先拆分任务或串行；不要同时改同一个热文件。
- 只改任务声明范围内的文件；发现需要越界，先在 PR/看板说明原因，或拆成新任务。

---

## 3. 开发与测试：完整验证，不靠感觉

### 3.1 基本验证（每次代码改动至少）

```bash
swift build --disable-sandbox     # 普通终端可去掉 --disable-sandbox
./scripts/test.sh --disable-sandbox
git diff --check
shasum -a 256 -c eval/FROZEN.sha256 --quiet
```

要求：

- **构建通过**、**全部测试通过**，才算代码完成。
- 失败时不要绕过、不要删测试、不要把断言改松；先定位原因。
- 如果环境限制导致无法运行（权限、网络、沙箱），在 PR 里明确写“未运行/需人工验证”，不得写成已通过。
- 测试输出要保留关键行：测试数、suite 数、耗时、失败项。

### 3.2 按改动类型追加

| 改动类型 | 追加验证 |
|---|---|
| Core / 触发 / 上下文 | `EVAL_ASR=0 scripts/eval.sh`；记录冻结评测 before/after |
| ASR / 发版 | 完整 `scripts/eval.sh` |
| 设置 / UI / 权限 | `--selftest-*`（隔离临时 `CFFIXED_USER_HOME`）+ 人工 UI 验收 |
| 长对话 / 性能 | 3000 句性能测试、内存/耗时对比 |
| 安全 / 隐私 | 个人信息、密钥、绝对路径扫描；不保存音频/截图 |

正式指标只认冻结评测；扩展评测只能作为“参考”，不能冒充正式结果。

### 3.3 编译出 app（功能/Bug 修复必须）

代码改动完成后，按项目脚本编译 app（本仓库为 `./build.sh`）：

```bash
./build.sh
codesign --verify --deep --strict --verbose=2 build/MeetingCopilot.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/MeetingCopilot.app/Contents/Info.plist
```

- 记录 app 路径、版本号、签名结果、启动结果。
- 需要真实麦克风/会议/按键的验收，标「需人工验证」，不要声称已解决。
- 纯文档改动可以不编译 app，但必须做 `git diff --check`、链接/命令检查，并在 PR 说明“未改代码”。

---

## 4. 单 app 纪律：一次构建只保留一个版本

### 4.1 核心规则

- **同一时间只有一个 `MeetingCopilot.app`、一个运行实例。**
- 构建前先结束旧实例；构建后清理其他工作树里的同名 app；启动前再确认一次。
- 不在主 clone 和开发工作树各留一个 app；不把 app 复制来复制去。
- 旧版本 app、旧 DMG、临时打包目录不要留在仓库/工作区里制造混淆；构建产物全部是 gitignored，禁止提交。
- 版本号以 `Info.plist` 和 `codesign` 为准，不以文件名/图标为准。

### 4.2 标准流程

```bash
# 1) 结束所有旧实例（只匹配本 app，不要 pkill 整个进程名）
pkill -f '/MeetingCopilot.app/Contents/MacOS/MeetingCopilot' 2>/dev/null || true

# 2) 在当前开发工作树构建
./build.sh

# 3) 删除其他工作树里的同名 app（只删 build 产物，不删源码）
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
  [ "$wt" = "$PWD" ] && continue
  rm -rf -- "$wt/build/MeetingCopilot.app"
done

# 4) 验证：应该只有一个 .app、一个进程
find .. -maxdepth 4 -type d -name 'MeetingCopilot.app' -print
pgrep -fl 'MeetingCopilot.app/Contents/MacOS/MeetingCopilot' || true
```

如果输出不是“一个 app / 一个进程”：**停下来清理**，不要继续验收或截图。

### 4.3 合并/发布后的处理

- 合并回集成分支后，在集成工作树重新构建，删除开发工作树的旧 app。
- 发布前再确认版本号、签名、单 app；不要用旧 app 冒充新版本。
- 删除任何 `build/` 下的旧 app 前，确认绝对路径是构建产物，不要误删源码或用户数据。

---

## 5. Commit 规范

### 5.1 格式

```text
<type>(<scope>): <subject>

<为什么改 / 改了什么 / 怎么验证>

Task: T-xxx
Agent: claude|dsh
Tested-by: user        # 只有用户确实验收过才写
```

- `type`：`feat` / `fix` / `docs` / `test` / `refactor` / `chore` / `perf`。
- `scope`：模块或文件范围，例如 `composer`、`turn-detector`、`eval`、`settings`。
- `subject`：一句话说清功能，≤ 72 字符，不要“update”“fix bug”“misc”。
- 正文写清：背景/原因、行为变化、验证命令与结果、影响/风险。
- 一个 commit 只做一件逻辑上的事；不要把重构、格式化、功能混在一起。
- 不提交构建产物、`.build/`、`build/`、音频、截图、密钥、个人信息、本机绝对路径。

### 5.2 示例

```text
fix(composer): 补充提问输入框支持多行换行

原输入框是单行 TextField，回车会直接提交；macOS 14 的 vertical
TextField 也无法用键盘回车换行（粘贴多行可以）。改用 TextEditor
（NSTextView）后回车插入换行，固定 72 高，超出滚动。

验证：swift build 通过；46 个测试 / 10 个 suite 通过；
build.sh 产出并签名 app，用户已手动验收多行输入与 ⌘↩ 发送。

Task: T-006
Agent: dsh
Tested-by: user
```

### 5.3 历史整理

- 同一个分支上多次 fixup 导致提交信息混乱时，PR 前可以 squash 成一个清晰提交。
- 只对**未推送、未被别人使用**的分支做 rebase/squash；已推送分支追加新提交，不改写历史。

---

## 6. PR 规范

### 6.1 标题

与主提交一致，清晰表达功能：

```text
fix(composer): 补充提问输入框支持多行换行
docs(agents): 新增公共 Agent 开发手册
feat(settings): 按接口类型记住 Base URL 与模型
```

不要用：

```text
update
fix
修改
测试一下
```

### 6.2 正文模板

```markdown
## 功能
一句话说明用户能感知的变化。

## 背景 / 原因
为什么做；旧行为是什么；为什么旧方案不行。

## 改动
- 文件 / 模块：改了什么
- 行为变化：旧 → 新
- 非目标：明确没做什么

## 验证
- 命令 + 结果（构建、测试数、冻结校验、评测 before/after）
- app 路径 / 版本 / 签名 / 启动结果
- 单 app 校验：1 个 .app、1 个进程

## 影响与风险
兼容性、性能、权限、隐私、回滚方式。

## 人工验收
需要用户手动确认的清单（UI、真实麦克风、真实会议、真实按键）。

## 任务
Task: T-xxx；关联 issue / 看板。
```

### 6.3 规则

- 目标分支：有 `dev` 用 `dev`，没有则 `main`；发布相关改动先问用户。
- 一个 PR 只做一件事；不要夹带无关改动。
- UI 改动附截图/录屏，且不能包含个人信息、真实会议内容。
- 不在 PR 里写密钥、账号、本机绝对路径、用户隐私数据。
- 不自己合并自己的 PR；等用户审核。合并由用户或用户指定的人执行。
- 合并后删除任务分支；集成者更新项目状态文档；重新构建集成 app 并清理旧 app。

---

## 7. 评审与合并

评审检查项：

- [ ] 目标与分支名一致，改动范围没有越界
- [ ] 行为改动有测试；测试不是删断言/放宽断言
- [ ] 构建、测试、冻结校验通过；证据可复现
- [ ] 正式/扩展评测口径正确，没有把参考值当正式值
- [ ] 没有个人信息、密钥、绝对路径、真实会议数据
- [ ] 没有未批准的产品行为/阈值/重新冻结
- [ ] app 已编译、签名、版本正确，且只有一个 app
- [ ] PR 描述清楚，人工验收项明确
- [ ] 回滚方式明确

评审意见分级：

- **blocker**：必须改，否则不能合并。
- **suggestion**：可以后续处理，不阻塞。
- **question**：需要作者/用户确认。

两轮内无法达成一致，升级给用户决策，不要互相覆盖。

---

## 8. 冲突预防与处理

预防：

1. 开工前同步最新基线（第 2 节）。
2. 看板/任务写清文件范围；一个文件同一时间只有一个 writer。
3. 分支短生命周期；PR 小而聚焦。
4. 不直接改别人的分支/工作树。
5. 发现基线前进，先 rebase，再重跑验证。

处理：

- 合并冲突：作者 rebase 到最新目标分支，逐个人工解决；不要用 `-X ours/theirs` 糊过去。
- 解决后重跑构建、测试、评测、编译、单 app 校验。
- 冲突涉及别人未合并的工作：停下来沟通，不要替对方做决定。
- 不要 `git reset --hard` 别人的工作树，不要删除别人的分支。

---

## 9. 安全与红线

- 不申请辅助功能权限；不模拟键鼠；不操控其他 App。
- 不保存音频、截图；转写只在内存；导出由用户选择位置。
- 不上传/提交个人信息（姓名、邮箱、用户名、本机绝对路径、密钥）。
- 不修改冻结评测、评分逻辑、阈值；认为评测有错，写进项目状态文档的「需人工确认」。
- 不直接 push `main`/`dev`；不 force push；不改写共享历史。
- 不擅自发布 Release、公证、签名证书、钥匙串、TCC 权限；需要用户明确授权。
- 不删除用户数据、设置、模型缓存；清理只针对 gitignored 的构建产物。
- 不虚构测试结果；不能自动验证的，标「需人工验证」。
- 本手册要求编译 app 时，只构建/签名本项目产物；不改系统安全设置。

---

## 10. 完成定义（Definition of Done）

一个任务只有同时满足以下条件才算完成：

- [ ] 从最新基线开分支，分支名清晰
- [ ] 只改任务范围；必要的测试已新增
- [ ] 构建通过；测试全部通过；评测/冻结校验按类型完成
- [ ] app 已编译、签名、版本正确
- [ ] 只剩一个 app、一个进程；没有旧版本混淆
- [ ] commit 信息清晰，包含 why/what/verification
- [ ] PR 标题/正文清晰，包含验证证据和人工验收项
- [ ] 用户已审核/验收（产品行为、UI、真实设备）
- [ ] 合并后集成分支重新构建，旧工作树 app 已清理
- [ ] 项目状态文档已由集成者更新

---

## 11. 完成后的汇报模板

```text
分支：<branch>（base: <dev@commit>）
改动：<一句话 + 文件范围>
测试：<命令 + 结果；测试数/suite>
编译：<app 路径、版本、签名结果>
单 app：<1 个 .app、1 个进程；旧版本已清理>
PR：<链接 / 标题>
人工验收：<需要用户确认的项>
风险/未验证：<真实设备、权限、性能等>
```

汇报必须让用户能直接判断：**改了什么、有没有验证、现在该测哪个 app、还剩什么风险。**

---

## 12. 本仓库命令速查

```bash
# 同步
git fetch --all --prune
git status --short
git switch dev && git pull --ff-only

# 开发验证
swift build --disable-sandbox
./scripts/test.sh --disable-sandbox
git diff --check
shasum -a 256 -c eval/FROZEN.sha256 --quiet

# 快速评测（Core / 触发 / 上下文）
EVAL_ASR=0 scripts/eval.sh

# 完整评测（ASR / 发布前）
scripts/eval.sh

# 编译 app + 签名
./build.sh
codesign --verify --deep --strict --verbose=2 build/MeetingCopilot.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/MeetingCopilot.app/Contents/Info.plist

# 单 app 校验
find .. -maxdepth 4 -type d -name 'MeetingCopilot.app' -print
pgrep -fl 'MeetingCopilot.app/Contents/MacOS/MeetingCopilot' || true
```

> 在受沙箱限制的 agent 环境里，SwiftPM 可能需要 `--disable-sandbox`；普通终端可去掉。
> 需要真实麦克风、真实会议、真实按键的验证，必须由用户完成，agent 不得声称已通过。

---

## 13. 手册维护

- 本手册是公共基线；项目内 `CLAUDE.md`、`COLLAB.md`、`program.md` 可以补充更具体的规则，但不要降低安全/测试要求。
- 流程变化时，用独立 PR 修改本手册，写清变更原因和影响。
- 不要在本手册里写个人信息、本机绝对路径、密钥、真实会议内容。
- 如果仓库里同时存在多份 agent 规范，合并成一份；不要保留互相冲突的副本。
