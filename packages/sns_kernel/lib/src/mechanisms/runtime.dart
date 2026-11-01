/// A per-game registry. Content bindings never contain runtime instances.
/// New modules are registered by the adapter, not added as kernel fields.
final class MechanismRuntime {
  final Map<Type, Object> _modules = {};
  void register<T extends Object>(T module) {
    if (_modules.containsKey(T)) {
      throw StateError('Module already registered: $T');
    }
    _modules[T] = module;
  }

  T require<T extends Object>() =>
      (_modules[T] ?? (throw StateError('Module not registered: $T'))) as T;
}
