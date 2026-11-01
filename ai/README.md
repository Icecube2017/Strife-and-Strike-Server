# Strife-and-Strike 离线 AI

200k/300k 之后的当前操作与命令见 [下一阶段操作手册](../docs/AI_NEXT_STAGE_OPERATIONS.md)，包括新种子评测、策略质量检查、可选随机分支与后续开发顺序。完整对局和奖励基础见 [训练指引](../docs/AI_NEXT_STEPS.md)。2026-10-30 已退役旧缩水训练集，改为完整对局；当前观测v3支持256张牌，动作仍为v2。完整对局v2已有模型可[保留进度迁移](../docs/AI_CARD_CAPACITY_MIGRATION.md)。

## 现有能力

2026-11-01 已接通[受限搜索示范 → 模仿学习 → PPO 续训](../docs/AI_SEARCH_TRAINING.md)，默认深度 6 条内核命令、32 次模拟、1.5 秒计算预算。已完成 8 条示范、2 轮模仿和一次 2048 步 PPO 更新的流程验证；未认证对战强度。仍未接入正式房间或完整自博弈。早期[离线搜索诊断说明](../docs/AI_SEARCH_PROTOTYPE.md)保留供参考。

已修复选牌/取消/翻页循环、分裂封锁最后一个攻击目标，以及主动伤害目标和响应费用等[命令边界问题](../docs/COMMAND_BOUNDARY_AUDIT.md)。旧模型保留权重与优化器，采用新决策规则前需要显式升级；见[修复及继续评测指引](../docs/AI_DECISION_PROGRESS_FIX.md)。

- 无数据库、无 HTTP 的真实 Dart 内核对战，固定 rules/random 玩家。
- 正式 201 张默认牌堆、35种通用技能（每种3份，共105个抽取实例）和默认开局规则，四角色的单挑、2v2、混战课程。
- 有序组合牌采用逐张选择、选目标确认；撤回与取消不支付费用。最终提交复用内核校验。
- 玩家可见信息编码、合法候选分页、选择/准备/嵌套响应、弃牌、额外轮次。
- CPU MaskablePPO、模型及优化器续训、独立种子评测、实际模型动作回放。
- 可切换纯胜负奖励与胜负加评分奖励；胜率按实际胜负单独统计。

全角色、完整能力覆盖、正式房间机器人、自博弈和难度认证仍待制作。恋慕继续排除。具体边界见 `coverage.json`。

## 使用本机 Python

已经安装过依赖可直接继续使用；首次配置时在服务器根目录执行：

```powershell
python -m pip install -e "./ai[train]"
python -m sns_ai.train --config ai/configs/full-match-winloss.json --steps 10000 --out ai/runs/full-winloss-10k
python -m sns_ai.train --config ai/configs/full-match-hybrid.json --steps 10000 --out ai/runs/full-hybrid-10k
```

两组相同参数与 seed，只更换奖励。不要同时运行，避免争用 CPU 干扰比较。新输出目录必须不存在；步骤按完整 rollout 向上取整。Ctrl+C 一次等待完整更新保存，再次按下才立即中断。

## 对局与速度验证

```powershell
dart bin/ai_lab.dart scenarios
dart bin/ai_lab.dart smoke --games 56 --paired --seed 7001 --out ai/reports/new-smoke
dart tool/ai_reward_benchmark.dart 2
python -m pytest ai/tests
```

开关评分的基准保留相同正式统计观察器，只比较额外实时评分投影。它验证两组完整轨迹一致并记录耗时；不等于完整 PPO 性能结论。当前验证记录位于 `ai/reports/full-match-validation/`。

## 查看模型如何出牌

```powershell
$run = 'ai/runs/full-winloss-10k'
$model = Join-Path $run (Get-Content (Join-Path $run 'latest.json') -Raw | ConvertFrom-Json).model
python scripts/inspect_ai_policy.py --model $model --out ai/reports/my-policy-review
```

在浏览器打开输出的 `index.html`。可查看每步可见状态、本人手牌与技能、选择概率、实际动作、推进后状态；默认隐藏唯一合法操作。`--model` 可重复传入比较多份模型，`--scenario`/`--learner` 过滤场景，`--deterministic` 单独检查最高概率选择。概率不是胜率，也不是内部思考解释。

## 场景和契约

正式训练使用 `ai/scenarios/full-match/`。`trainingMode=fullMatch` 只允许正式默认牌堆、技能池和开局规则，不接受 `initial`、命令前缀或缩水规则。诊断测试可以在代码内创建自定义初始局面，但不允许经正式训练入口领取整局胜负奖励。

训练冻结执行内容、场景、词表和实现。v3 编码在候选中包含选牌阶段、已选顺序、卡牌槽位和是否能确认，完整保留最多256张牌；超过容量仍明确报错，不静默截断。旧 scalar-fused-v1 授权不能跨越规则/动作结构变化。`--resume` 仅用于相同新任务；改奖励应建独立实验，不能直接续训另一组。

原始评分读取既有统计，计算公式和奖励上下界见 [训练指引](../docs/AI_NEXT_STEPS.md)。本轮短训仅验证流程，不代表棋力验证。

评测支持逐局落盘与 `--resume` 恢复；固定玩家的长段自动推进按256次操作分批返回，模型只接收原有决策点。详见[评测超时与恢复](../docs/AI_EVALUATION_RECOVERY.md)。
