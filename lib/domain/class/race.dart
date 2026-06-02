import 'package:sns_server/domain/core/core.dart';

abstract class Race extends Identifiable {
  String get name;
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
  final String name;
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
    this.name,
    this.regenerationType,
    this.maxMP,
    this.initialMP,
    this.regenerationValue,
    this.regenerationInterval
  );

  factory BaseRace.fromJson(Map<String, dynamic> json) =>
    BaseRace(
      json["id"] as String,
      json["name"] as String,
      json["regenType"] as int,
      json["maxMp"] as int,
      json["initMp"] as int,
      json["regenMp"] as int,
      json["regenInterval"] as int);
}

