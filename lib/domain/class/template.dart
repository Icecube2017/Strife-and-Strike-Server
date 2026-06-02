import 'dart:convert';

import 'package:sns_server/domain/core/core.dart';

abstract class Template extends Identifiable {
  String get name;
  int get hp;
  int get attack;
  int get defense;
}

class BaseTemplate implements Template {
  @override
  final String id;
  @override
  final String name;
  @override
  final int hp;
  @override
  final int attack;
  @override
  final int defense;

  BaseTemplate(this.id, this.name, this.hp, this.attack, this.defense);

  factory BaseTemplate.fromJson(Map<String, dynamic> json) =>
    BaseTemplate(
      json['id'] as String,
      json['name'] as String,
      json['hp'] as int,
      json['attack'] as int,
      json['defense'] as int);
}
