# sns_kernel

Pure Dart kernel-v2, executable JSON decoding, and conditional attack previews. No Flutter, HTTP, database, file or clock dependency. The server consumes this package through a path dependency; legacy server imports re-export it.

```dart
import 'package:sns_kernel/sns_kernel.dart';
final content = ExecutableContent.decode(contentJson);
final snapshot = PreviewState(snapshotJson);
final result = PreviewRunner(content.catalog,
  contentHash: executableContentHash(contentJson)).run(snapshot, request);
```

See ../../COMBAT_PREVIEW.md for visibility, budgets and incomplete-projection limits. Run `dart pub get`, `dart test`, and `dart analyze lib test` in this directory. Never feed a preview's mutable state back into a live game.

### 首回合 MP 恢复兼容

恢复检查点以 `firstRoundMpRecovery` 固定首回合自然回复行为。新局为 false；缺少字段的旧检查点根据 verification 中第一回合的 mpRegenerated 事实识别旧行为，仍完整校验重放结果，不豁免费用检查、不改写历史行动。修复旧局恢复时重算费用不足，导致包括结束轮次在内的所有新命令失败。没有版本标记、也尚未发生相关回复的旧记录无法唯一识别，按当前规则处理；后续规则变更应保存明确版本或策略。

### 交互版本 10

新局使用 `interactionRulesVersion: 10`，预览兼容标识为 `kernel-v2-preview-8`。检查点继续保留旧局版本，内容也须使用该局固定的定义。

- 道具可配置 `reinforcedDiceSides`，指定强化后的攻击骰面；初投、无效化后的重投、骰点选择上限与预览共用此数值。当前六方棱／八重镜／十面璃为 8／12／16。
- 道具的 `response` 可为 `dodge` 或 `counterDodge`。使用 `RespondCardCommand(playerId, windowId, cardInstanceId)`；HTTP 复用 `respond`，`optionId` 为 `card:<instanceId>`。执行前验证座次、手牌所有权、费用与出牌限制，提交前的选择不公开。
- `effects` 在攻击计算前执行，`onHit` 在攻击结算中执行；补天石的 `statusStackMultipliers` 同时适用于两处的状态附加。强化的偷牌、弃牌、清 CD 逐项选择，选择信息带有 `selectionIndex`／`selectionCount`。
- 正式中立状态使用 `neutral: true`；其仍属于状态效果，但气象万千的自身正面状态筛选不包含它。`isStatusEffect: false` 表示内部临时效果；真正的 mark 使用独立的 marks 定义与运行时存储，显示用 Wiki 数据不能改变执行分类。
