import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/domain/class/character.dart';

// POST /rooms — 创建房间
// host 角色暂时用空 BaseCharacter 占位，实际应从角色选择流程传入
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  final body = await context.request.json() as Map<String, dynamic>;
  final req = CreateRoomRequest.fromJson(body);
  final characterId = body['characterId'] as String? ?? 'empty';

  final service = context.read<RoomService>();
  // TODO: 从 characterReg 加载角色；此处用一个 stub
  final hostChar = _stubCharacter(characterId);
  final resp = await service.createRoom(req, hostChar);
  return Response.json(statusCode: 201, body: resp.toJson());
}

/// 临时占位：从 registry 加载角色（接通 assets 后替换）
Character _stubCharacter(String id) =>
    CharacterFactoryCreated(id, id, 'balanced', 'human', {}, [], []);
