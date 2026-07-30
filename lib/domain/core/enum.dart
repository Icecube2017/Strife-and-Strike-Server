// 玩家轮次各阶段
enum TurnPhase {
  start,
  draw,
  action,
  discard,
  end
}

/// 引擎当前所处的流程节点
enum FlowState {
  bootstrapping,
  turnOpening,
  mainDecision,
  responseWindow,
  resolvingStack,
  forcedDecision,
  discardDecision,
  turnClosing,
  finished,
}

// 玩家动作类型
enum ActionType {
  attack,
  playCard,
  attackCard,
  limitedCard,
  skill,
  trait,
  passPriority,
}

/// 掷骰用途分类。
enum DiceRollReason {
  attackDamage,
  skillDamage,
  traitEffect,
  statusEffect,
  generic,
}

/// 栈上动作当前推进到的结算阶段。
enum PendingActionStage {
  declared,
  resolving,
  waitingResponse,
  effectResolved,
  diceResolved,
  damagePrepared,
  resolved,
  cancelled,
}

/// 响应动作对栈上既有动作施加的修改类型
enum StackMutationType {
  cancelAction,
  replaceTarget,
  patchPayload,
  setPayloadField,
  removePayloadField,
  setDiceResult,
}

/// 当前等待玩家做出的决策类型
enum DecisionType {
  action,
  response,
  forcedSelection,
  discard,
  passPriority,
}

/// 对局最终结果类型
enum GameOutcomeType {
  victory,
  defeat,
  draw,
}

// 伤害类型
enum DamageType {
  physical,
  magical,
  real,
  loss
}

// 伤害来源
enum DamageSource{
  action,
  effect,
  card,
  skill,
  trait,
  status,
  lost,
  scene
}

// 治疗类型
enum HealType {
  heal,
  revive,
}

// 治疗来源
enum HealSource{
  action,
  effect,
  card,
  skill,
  trait,
  status,
  heal,
  scene
}

enum CharacterTag {
  // 定位Tag
  empty,
  cd,
  mp,
  dpr,
  burst,
  survive,
  defense,
  support,
  control,
  anticon,
  buff,
  debuff,
  // 阵营Tag

  // 地区Tag
  narranlo,
}

enum PropCardTag {
  sharp,      // 锋锐
  shield,     // 铁御
  life,       // 生机
  fate,       // 命运
  arcane,     // 秘法
  illusion,   // 幻相
  mana,       // 魔能
  trick,      // 诡术
  chaos,      // 失序
  sense,      // 感知
}

enum StatusStacking {
  max, // 取最高强度，层数累加
  add, // 强度和层数直接相加
}

/// 修饰器类型
enum ModifierType {
  additive,       // 加法
  multiplicative, // 乘法
  override,       // 覆盖
}

/// 属性类型
enum PropertyType{
  health, 
  maxHp, 
  attack, 
  defense, 
  armor, 
  movepoint, 
  maxMove, 
  maxCard,
  dmgDealt,
  dmgReceived,
  curDealt,
  curReceived,
  actionTime,
  jumpedTurn
}
