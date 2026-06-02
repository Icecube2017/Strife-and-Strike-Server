// 玩家轮次各阶段
enum TurnPhase {
  start,
  draw,
  action,
  discard,
  end
}

// 玩家动作类型
enum ActionType {
  attack,
  attackCard,
  limitedCard,
}

// 伤害类型
enum DamageType {
  physical,
  magical,
  real,
  loss
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
