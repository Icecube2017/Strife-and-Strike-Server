import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/data/ids.dart';

abstract class Template extends Identifiable {
  int get hp;
  int get attack;
  int get defense;
}

class BaseTemplate implements Template {
  @override
  final String id;
  @override
  final int hp;
  @override
  final int attack;
  @override
  final int defense;

  BaseTemplate(this.id, this.hp, this.attack, this.defense);

  factory BaseTemplate.fromJson(Map<String, dynamic> json) =>
    BaseTemplate(
      json['id'] as String,
      json['hp'] as int,
      json['attack'] as int,
      json['defense'] as int);
}

class TemplateRepo {
  TemplateRepo();

  Map<String, Template> templates = {
    TemplateId.empty.id: BaseTemplate(TemplateId.empty.id, 0, 0, 0),
    TemplateId.defensive.id: BaseTemplate(TemplateId.defensive.id, 1350, 65, 65),
    TemplateId.supportive.id: BaseTemplate(TemplateId.supportive.id, 1350, 80, 50),
    TemplateId.balanced.id: BaseTemplate(TemplateId.balanced.id, 1350, 95, 35),
    TemplateId.challenging.id: BaseTemplate(TemplateId.challenging.id, 1350, 105, 25),
    TemplateId.brutal.id: BaseTemplate(TemplateId.brutal.id, 1200, 125, 20),
    TemplateId.vital.id: BaseTemplate(TemplateId.vital.id, 1600, 75, 45),
    TemplateId.defen5.id: BaseTemplate(TemplateId.defen5.id, 0, 105, 25),
  };

  Template get(String id) => templates[id] ?? templates[TemplateId.empty.id]!;
}
