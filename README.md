# Strife and Strike Server

[![style: dart frog lint][dart_frog_lint_badge]][dart_frog_lint_link]
[![License: MIT][license_badge]][license_link]
[![Powered by Dart Frog](https://img.shields.io/endpoint?url=https://tinyurl.com/dartfrog-badge)](https://dart-frog.dev)

Strife and Strike Server built with dart_frog

2026-10-27：客户端使用独立的 `sns-client` 协议主／次版本、资料格式与必需 UI 能力检查，不再要求内核修订号一致，也不使用对外内容哈希。客户端只读取显示／操作元数据，伤害由服务端计算；切换需要更新一次客户端，后续普通内核和配置调整无需配套重建安装包。规范见 [docs/CLIENT_PROTOCOL.md](docs/CLIENT_PROTOCOL.md)，规则见 [RULE.md](RULE.md)。

本地持久化已改为 SQLite，不需要 PostgreSQL 服务或 PG_* 环境变量。
在服务器目录执行（PowerShell）：

```powershell
dart pub get
.\run.bat
```

Windows 启动脚本默认监听 `127.0.0.1:22216`（frp 的本地转发目标保持该端口）。
启动窗口内按 **R** 完整重启，按 **Q / S** 停止；也可在另一个终端运行：

```powershell
.\run.bat status
.\run.bat stop
.\run.bat restart
```

双击 `stop.bat` / `restart.bat` 也可停止／重启；服务器未运行时，`restart.bat`
会在当前窗口启动。修改端口用 `run.bat start -Port 3000`，后续控制命令也需要传
`-Port 3000`。修改默认端口可编辑 `scripts/server.ps1` 顶部的 `$Port`。
`-VmServicePort` 可调整 Dart 调试端口，默认 8181。

启动脚本通过 Windows Job Object 管理本次服务器及其所有子进程：正常停止先发送
Ctrl+C，最多等待 8 秒，再清理残留进程；直接关闭启动窗口或管理进程异常退出时，
Windows 自动终止该进程树。不会按 `dart.exe` 名称批量结束进程，也不会结束碰巧
占用端口的其他程序。重复启动会报错，不会叠加实例。旧方式启动的进程不属于此管理器，
需要先在旧窗口停止一次，再改用 `run.bat`。若控制窗口卡住可用 `run.bat stop -Force`
直接清理本管理器的进程树。

运行日志位于 `.dart_tool/server-control/<端口>/`。端口、状态与进程归属由实际进程和
Windows 同步对象确认，遗留的 `state.json` 不会阻止再次启动。停止／重启会断开客户端
连接；进行中的未提交请求可能中断，备份数据库仍应先正常停止服务器。
脚本保留 `dart_frog dev` 的文件监听与热重载；完整重启会重新载入内容和配置。
管理脚本自检：`powershell -File tool/check_server_control.ps1`，使用随机端口和临时
进程检查停止、重启、进程异常退出及端口冲突；加 `-RealServer` 可额外验证真实
健康接口；应用源码、生成文件和数据库均隔离到临时目录，不会重启正在运行的正式服务。

首次请求自动创建 `data/server/sns.sqlite` 及所有表，后续自动恢复房间和对局。
可用 `SQLITE_PATH` 覆盖文件路径；相对路径以启动工作目录为准。`JWT_SECRET` 沿用
现有配置，重启时保持一致。切换数据库依赖后需完整停止并重新启动服务。
旧 PostgreSQL 数据不会自动导入；旧 scripts/migrations 下的 PostgreSQL SQL 不用于
SQLite。SQLite schema 由代码中的 `PRAGMA user_version` 管理并在事务中初始化。
运行 `dart run tool/check_sqlite_startup.dart` 使用临时数据库和随机本地端口检查
健康接口、内容下载、注册及建房，不会修改运行中的服务器或正式数据。

数据库含用户密码哈希、令牌哈希和隐藏对局存档，不是公共静态文件。备份时停止
服务器后复制整个 `data/server` 目录；运行中不能仅复制主文件而遗漏 WAL 数据。
默认使用 WAL、FULL 同步和 5 秒 busy_timeout，按单服务器进程运行。

Flutter 客户端启动内容接口：`GET /api/v1/content`，无需登录，只返回当前进程加载的
去文案资料、所选 `deckId`、`protocol`、`contentSchemaVersion` 和 `requiredFeatures`，不含对局状态。
修改服务器内容文件后需要重启服务才会更新该接口。正在进行的对局仍使用各自固定的
`GET /api/v1/games/{gameId}/preview/content` 快照（需要参与者登录）。
房间及游戏 SSE 均每 15 秒发送注释心跳，并返回 `X-Accel-Buffering: no`；frp 前面的
反向代理仍需要关闭事件流缓冲并允许长连接。客户端可以保存公开日志副本，服务器
检查点和归档继续作为权威记录。

定义驱动游戏内核的入口、规则约定及阶段边界见 [KERNEL.md](docs/KERNEL.md)。
运行 `dart run example/wiki_match.dart` 可在不启动 HTTP 或数据库的情况下使用执行 JSON 完成一局对战。
内容编辑入口为 `content/content_items.json`，字段类型、默认值与配置示例见 [CONTENT_FIELDS.md](docs/CONTENT_FIELDS.md)。
守备、风云、追击、时印等机制新增数值字段及默认值见 [docs/CONFIGURABLE_NUMBERS.md](docs/CONFIGURABLE_NUMBERS.md)。
全部字段可选值见 [CONTENT_OPTIONS.md](docs/CONTENT_OPTIONS.md)，中文日志配置见 [GAME_LOGS.md](docs/GAME_LOGS.md)。
伤害与治疗统计的口径、事件钩子和输出结构见 [COMBAT_STATISTICS.md](docs/COMBAT_STATISTICS.md)。
编写流程和复杂机制扩展思路见 [CONTENT_AUTHORING.md](docs/CONTENT_AUTHORING.md)。

拉取云端 wiki：使用 Python 3.10+，无需安装依赖。在 `scripts/wiki.local.json`
填写 `base_url`（Worker 服务地址）和 `token`，然后在本项目目录执行：

```sh
python scripts/pull_wiki.py
```

新检出项目时可复制 `scripts/wiki.example.json` 为 `scripts/wiki.local.json`。
也可通过 `API_BASE_URL`、`API_TOKEN` 环境变量覆盖配置，或用 `--base-url` 指定地址。
默认配置和输出路径相对于脚本所属项目，不受当前工作目录影响；显式传入的相对路径则相对于当前目录。
输出为 `data/wiki/snapshot.json`，保留 revision、server_time 和全部 8 类原始数据。
配置文件和默认输出目录已加入 `.gitignore`；如使用 `--config` / `--output` 自定义路径，需自行忽略这些路径。
脚本只调用 `GET /api/data`，成功后原子替换本地快照，失败保留原数据；不做内容字段或引用校验，也不自动导入游戏内核。
运行 `python scripts/pull_wiki.py --help` 查看参数。

[dart_frog_lint_badge]: https://img.shields.io/badge/style-dart_frog_lint-1DF9D2.svg
[dart_frog_lint_link]: https://pub.dev/packages/dart_frog_lint
[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT

共享 Dart 内核已抽入 `packages/sns_kernel`；服务端攻击试算与安全快照接口见 [COMBAT_PREVIEW.md](docs/COMBAT_PREVIEW.md)。

对战 AI 已实现受限四角色的离线场景、合法候选、随机／规则人机、Gymnasium 与 CPU 模型训练，见 [AI 工具入口](ai/README.md)。环境准备见 [训练环境指南](docs/AI_GYMNASIUM.md)，混合任务训练与评测按 [当前操作指南](docs/AI_NEXT_STEPS.md) 执行。完整路线见 [AI_TRAINING_PLAYBOOK.md](docs/AI_TRAINING_PLAYBOOK.md)；正式房间人机仍待接入。当前伤害快照限制见 [DAMAGE_PREVIEW_LIMITS.md](docs/DAMAGE_PREVIEW_LIMITS.md)。

房间成员、可暂停对局和结束归档的保存／恢复见 [GAME_RECOVERY.md](docs/GAME_RECOVERY.md)。SQLite 在启动时自动初始化和迁移，旧局严格恢复限制以该文档为准。

登录后按4位号码加入房间、改规则、组队、Ban和自动选角开局的协议见 [LOBBY_PROTOCOL.md](docs/LOBBY_PROTOCOL.md)。

客户端内容及事件不含名称、描述、选项文案及可读错误；用户自定 nickname 单独用于房间展示；前端按 ID 和机器码展示。传输边界见 [docs/WIRE_PROTOCOL.md](docs/WIRE_PROTOCOL.md)，版本兼容见 [docs/CLIENT_PROTOCOL.md](docs/CLIENT_PROTOCOL.md)。


房间全体成员连续断线20分钟后自动关闭并释放房间号；房间与对局 SSE 合并判断在线，重连取消计时。过期时删除未完成对局，保留正常结束的历史战绩；截止时间持久化并在重启后恢复，详见 [docs/GAME_RECOVERY.md](docs/GAME_RECOVERY.md)。

2026-10-16：支持昵称修改 `PATCH /api/v1/auth/me`（SQLite 自动迁移至 user_version=2，旧用户昵称默认账号名）、随机／手动交替座次及独立房主身份；新房间人数 2～8、每人 Ban 上限 1～3。相转移加入死亡判定前的目标选择与骰点响应续接。客户端应同步更新以使用昵称、完整 BP 目录和操作可用字段，具体见 docs/LOBBY_PROTOCOL.md、docs/WIRE_PROTOCOL.md。


2026-10-16客户端第3轮通信调整：新局interactionRulesVersion=2。普通行动响应排除发动者，
但记录自身行动保留recordAction/pass选项；独立骰点响应仍按技能时机开放。非操作者的私有
choice/preparation和非参与者的私有responseWindow为null，公开等待元数据继续保留。
操作者的choice.source仅包含kind和definitionId，用于客户端解释被动触发来源。
公开logEvents在现有schemaVersion=2下补充phase/extraTurn，已完成的traitTriggered或
skillTriggered可附带displayBeforeSequence作为界面排列锚点；内核事实顺序及统计不变。
服务器预运算分支增加damageObserved，未算到伤害且stoppedAt存在的分支不能当作确定0。
旧存档0/1保留旧响应／可见性语义，恢复时仍执行原有完整重放校验；需重启服务并新开对局
使用版本2交互。本轮相关静态检查通过，完整测试1174项通过，未改动运行中的数据库或服务进程。


2026-10-17第四轮：修复伤害检查点一次性技能移除后续接越界。旧局保留历史遍历并增加边界保护；
新局interactionRulesVersion=3使用稳定技能集合，避免相邻技能被跳过，并复查恢复后的技能持有与费用。
公开logEvents.events[]可选timestamp为UTC时间，服务层按提交批次记录并将eventTimes原子保存进恢复文档，
不参与内核确定性事实；旧历史无时间时不补造。私有choice.presentation只包含显示预设与单选契约，
choice_presentation.dart补全结算技能来源，不向其他玩家暴露选择内容，也不改变内核检查点。
推送JSON与前端配置说明见客户端docs/CHOICE_DIALOGS.md，示例文件为docs/choice-example.json。
完整测试1186项通过，相关静态检查无问题；未修改运行中的数据库、重启服务或构建客户端安装包。

离线 AI 已有受限内容的 CPU 训练、模型保存续训和独立评测入口，首次操作见 [AI 训练操作指南](docs/AI_NEXT_STEPS.md)。

## 文档导航

当前规范、AI 训练与待办见 [服务端文档索引](docs/README.md)；阶段验收与旧审查见 [历史归档](docs/archive/README.md)。
