/// 时钟抽象，方便测试时注入固定时间
abstract class AppClock {
  DateTime now();
}

class SystemClock implements AppClock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now();
}
