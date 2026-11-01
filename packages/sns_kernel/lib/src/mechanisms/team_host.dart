import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class TeamMechanismHost implements MechanismChoiceHost {
  List<PlayerInstance> get players;
  bool get previewMode;
  bool enemy(CharacterInstance a, CharacterInstance b);
  CharacterInstance character(String id);
  void effects(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
  );
  void runAbility(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
    void Function() complete,
  );
  void payMp(CharacterInstance actor, int amount);
  void consumeStatus(
    CharacterInstance actor,
    StatusInstance status, {
    int amount,
  });
  void enqueueFirst(void Function() continuation);
  VariableState variableCell(String id, CharacterInstance owner);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  void roll(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(int) complete,
  );
  int actionSeat(CharacterInstance actor);
  bool attackAllowed(CharacterInstance actor, CharacterInstance target);
  void automaticAttack(CharacterInstance actor, CharacterInstance target);
  bool isAutomatic(CharacterInstance actor);
  void Function() preserveContinuation(void Function() resume);
  void failMentalAction(CharacterInstance actor, CharacterInstance source);
  void resetNegativeMp(CharacterInstance source, CharacterInstance target);
}
