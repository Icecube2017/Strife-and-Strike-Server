import 'dart:math';

/// 随机数抽象，方便测试时注入固定种子
abstract class AppRng {
  int nextInt(int max);
  double nextDouble();
}

class SystemRng implements AppRng {
  final Random _random;
  SystemRng([int? seed]) : _random = Random(seed);

  @override
  int nextInt(int max) => _random.nextInt(max);
  @override
  double nextDouble() => _random.nextDouble();
}
