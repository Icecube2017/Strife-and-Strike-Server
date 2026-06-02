import 'dart:convert';
import 'dart:io';

import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/template.dart';

/*
class Assets {
  Assets._();
  static final Assets _instance = Assets._();
  factory Assets() => _instance;

  final Map<String, LangInfo> _allLangInfoZH = {};
  final Map<String, Template> _allTemplates = {};
  final Map<String, Race> _allRaces = {};
  final Map<String, CardPack> _allCardPacks = {};

  Future<String> _readAsset(String fileName) async {
    final file = File('assets/$fileName');
    return file.readAsString();
  }

  Future<void> loadLangInfosZH() async {
    final jsonString = await _readAsset('lang_zh.json');
    final jsonList = json.decode(jsonString) as List<dynamic>;
    for (var e in jsonList) {_allLangInfoZH[e["id"]] = LangInfo(e);}
  }

  Future<void> loadTemplatesJson() async {
    final jsonString = await _readAsset('templates.json');
    final jsonList = json.decode(jsonString) as List<dynamic>;
    for (var e in jsonList) {_allTemplates[e["id"]] = BaseTemplate.fromJson(e);}
  }

  Future<void> loadRacesJson() async {
    final jsonString = await _readAsset('races.json');
    final jsonList = json.decode(jsonString) as List<dynamic>;
    for (var e in jsonList) {_allRaces[e["id"]] = BaseRace.fromJson(e);}
  }

  Future<void> loadCardPacks() async {
    final jsonString = await _readAsset('races.json');
    final jsonList = json.decode(jsonString) as List<dynamic>;
    for (var e in jsonList) {_allCardPacks[e["id"]] = BaseCardPack.fromJson(e);}
  }

  Race getRace(String id) => _allRaces["race_$id"]!;
  Template getTemplate(String id) => _allTemplates["template_$id"]!;
}

class LangInfo {
  final Map<String, String> localNames;

  LangInfo(this.localNames);
}
*/

