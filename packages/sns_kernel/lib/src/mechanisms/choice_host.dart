import 'package:sns_kernel/src/state.dart';

abstract interface class MechanismChoiceHost {
  bool traitsBlocked(CharacterInstance actor, {String? exceptStatus});
  void choose(
    CharacterInstance actor,
    List<Map<String, Object?>> options,
    void Function(Map<String, Object?>) resolve,
  );
  void emit(String type, Map<String, Object?> data);
}
