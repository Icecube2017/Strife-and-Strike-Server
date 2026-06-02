 ## 1. 先定边界：把 lib/ 变成纯游戏领域层
  你现在的 GameEngine + GameState + EventBus 已经是核心雏形，建议固定成三层：

  1. Domain（纯规则）
     放你现在的 class/、core/，不依赖 Dart Frog、数据库、网络。

  2. Application（用例编排）
     负责“创建房间、加入、开始、出牌、结束回合”等流程，调用 Domain。

  3. Interface/Infrastructure（Dart Frog + 存储 + 缓存）
     路由、鉴权、中间件、Repo、消息推送都放这里。

  ———

 ## 2. 推荐目录（在现项目基础上演进）

  - lib/domain/：迁移 class/、core/、data/（逐步迁，不必一次做完）
  - lib/application/
      - commands/：play_card_command.dart、end_turn_command.dart
      - services/：game_service.dart、room_service.dart
      - dto/：请求/响应结构

  - lib/infrastructure/
      - repo/：game_repo.dart、room_repo.dart
      - cache/：内存或 Redis
      - messaging/：SSE/WebSocket 推送
      - clock_rng/：时间与随机数实现

  - routes/
      - /health
      - /auth/*
      - /rooms/*
      - /games/[gameId]/*
      - /_middleware.dart（鉴权、日志、trace id）

  ———

 ## 3. 核心运行模型：一局游戏 = 一个 RoomRuntime Actor
  每个 gameId 持有：

  - GameState
  - GameEngine
  - version（状态版本号）
  - commandQueue（串行处理命令，避免并发踩状态）
  - subscribers（推送连接）

  关键点：
  所有动作都走“命令队列串行化”，不要在路由里直接改 GameState。这能避免同回合并发请求导致状态错乱。

  ———

 ## 4. API 设计（最小可用）

  1. POST /rooms：创建房间
  2. POST /rooms/{id}/join：加入房间
  3. POST /rooms/{id}/ready：准备
  4. POST /rooms/{id}/start：开局（初始化牌堆/角色）
  5. GET /games/{id}/state：拉取状态（支持 ?sinceVersion=）
  6. POST /games/{id}/commands：提交动作命令
  7. GET /games/{id}/events：订阅事件流（SSE 或 WS）

  commands 建议统一格式：

  - commandId（幂等）
  - playerId
  - actionType（对应你现有 ActionType）
  - payload
  - clientVersion

  ———

 ## 5. 状态可见性：做“视图投影”，不要直接回传 GameState
  游戏有隐藏信息（手牌等），建议按玩家生成视图：

  - PublicGameView：全员可见信息
  - PlayerPrivateView：当前玩家私有信息
  - SpectatorView：观战视图（可选）

  服务端权威状态只有一份，返回前做 projection。

  ———

 ## 6. 事件与持久化策略（建议）
  先从简单到可扩展：

  1. MVP：内存状态 + 周期快照（JSON）
  2. 进阶：command log + event log + 快照
  3. 重启恢复：加载快照，再回放增量命令/事件

  这样你后续可以做“断线重连恢复、对局回放、争议审计”。

  ———

 ## 7. 你当前代码需要重点规避的运行风险

  1. _nextTurn() 递归回合推进，长期运行有栈风险，建议改成循环/调度驱动。
  2. EventBus.emit 同步触发，监听器里若有耗时逻辑会阻塞回合。建议区分同步事件和异步任务。
  3. 领域模型中出现服务端/工程路径耦合迹象（例如 import 风格不一致），后续要统一包边界。
  4. GameState 目前可变字段很多，建议加“命令入口唯一化”，避免路由直接写状态。

  ———
  1. Domain tests：回合、伤害、状态、卡牌效果（纯单测，固定随机种子）
  2. Application tests：命令编排、非法操作拦截、版本冲突
  3. Route tests：鉴权、参数校验、状态码、响应结构
  4. Soak tests：多局并发、断线重连、重复命令幂等

  ———

## 8. 目前的 TODO（非阻塞，可逐步接通）：
  1. auth/index.dart：换成真实 JWT 签发/验证
  2. rooms/index.dart 和 join/：从 characterReg 加载实际角色，而不是 stub
  3. start/index.dart：从 assets 构造完整牌堆