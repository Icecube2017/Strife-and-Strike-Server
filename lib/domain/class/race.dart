import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/data/ids.dart';

abstract class Race extends Identifiable {
  int get regenerationType;
  int get maxMP;
  int get initialMP;
  int get regenerationValue;
  int get regenerationInterval;
}

class BaseRace extends Race {
  @override
  final String id;
  @override
  final int regenerationType;
  @override
  final int maxMP;
  @override
  final int initialMP;
  @override
  final int regenerationValue;
  @override
  final int regenerationInterval;
  BaseRace(
    this.id,
    this.regenerationType,
    this.maxMP,
    this.initialMP,
    this.regenerationValue,
    this.regenerationInterval
  );

  factory BaseRace.fromJson(Map<String, dynamic> json) =>
    BaseRace(
      json['id'] as String,
      json['regenType'] as int,
      json['maxMp'] as int,
      json['initMp'] as int,
      json['regenMp'] as int,
      json['regenInterval'] as int);
}

class RaceRepo {
  RaceRepo();

  Map<String, Race> races = {
    RaceId.empty.id: BaseRace(RaceId.empty.id, 0, 0, 0, 0, 0),
    RaceId.human.id: BaseRace(RaceId.human.id, 0, 5, 0, 2, 1),
    RaceId.feline.id: BaseRace(RaceId.feline.id, 0, 6, 0, 2, 1),
    RaceId.humanFeline.id: BaseRace(RaceId.humanFeline.id, 0, 6, 0, 2, 1),
    RaceId.gryphon.id: BaseRace(RaceId.gryphon.id, 0, 4, 0, 3, 1),
    RaceId.dragon.id: BaseRace(RaceId.dragon.id, 0, 6, 0, 3, 1),
    RaceId.halfDragon.id: BaseRace(RaceId.halfDragon.id, 0, 5, 0, 5, 2),
    RaceId.columba.id: BaseRace(RaceId.columba.id, 0, 4, 0, 2, 1),
    RaceId.muridae.id: BaseRace(RaceId.muridae.id, 0, 3, 0, 3, 1),
    RaceId.caprinae.id: BaseRace(RaceId.caprinae.id, 0, 3, 0, 1, 1),
    RaceId.pseudois.id: BaseRace(RaceId.pseudois.id, 0, 3, 0, 2, 1),
    RaceId.machina.id: BaseRace(RaceId.machina.id, 0, 10, 0, 5, 5),
    RaceId.currus.id: BaseRace(RaceId.currus.id, 1, 5, 0, 0, 1),
    RaceId.experiment.id: BaseRace(RaceId.experiment.id, 0, 4, 0, 2, 2),
    RaceId.program.id: BaseRace(RaceId.program.id, 2, 4, 0, 0, 1),
    RaceId.lemures.id: BaseRace(RaceId.lemures.id, 0, 30, 30, -1, 1),
    RaceId.oni.id: BaseRace(RaceId.oni.id, 3, 5, 0, 0, 1),
    RaceId.anima.id: BaseRace(RaceId.anima.id, 0, 20, 20, 1, 2),
    RaceId.pseudosacra.id: BaseRace(RaceId.pseudosacra.id, 0, 10, 0, 10, 3),
    RaceId.elf.id: BaseRace(RaceId.elf.id, 0, 8, 0, 2, 1),
    RaceId.froth.id: BaseRace(RaceId.froth.id, 0, 7, 0, 4, 1),
    RaceId.nyxumbra.id: BaseRace(RaceId.nyxumbra.id, 0, 8, 0, 6, 2),
    RaceId.tinXingyu.id: BaseRace(RaceId.tinXingyu.id, 2, 5, 0, 0, 1),
    RaceId.valedictus.id: BaseRace(RaceId.valedictus.id, 0, 8, 0, 2, 1),
    RaceId.engine4.id: BaseRace(RaceId.engine4.id, 5, 100, 0, 0, 1),
    RaceId.ennoia.id: BaseRace(RaceId.ennoia.id, 0, 9, 0, 1, 1),
  };

  Race get(String id) => races[id] ?? races['empty']!;
}
