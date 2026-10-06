import 'dart:io';

import '../core/api_client.dart';
import '../models/models.dart';

/// 会议相关 REST 接口（对应后端 MeetingsController / RtcController）
class MeetingService {
  MeetingService(this._api);

  final ApiClient _api;

  /// 我的会议列表
  /// [scope] hosted=我发起的 / joined=我参加的 / 其它=全部
  /// [filter] waiting / ongoing / ended
  Future<List<Meeting>> list({String? scope, String? filter}) async {
    final data = await _api.get('/meetings', query: {
      if (scope != null && scope.isNotEmpty) 'scope': scope,
      if (filter != null && filter.isNotEmpty) 'filter': filter,
    });
    final list = (data as List?) ?? const [];
    return list.map((e) => Meeting.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<Meeting> create({
    required String subject,
    String mode = 'instant',
    String? description,
    DateTime? startTime,
    int durationMinutes = 60,
    String? password,
    bool waitingRoomEnabled = false,
    bool watermarkEnabled = false,
    String? recurrence,
    bool usePmi = false,
  }) async {
    final data = await _api.post('/meetings', data: {
      'mode': mode,
      'subject': subject,
      if (description != null && description.isNotEmpty) 'description': description,
      if (startTime != null) 'startTime': startTime.toIso8601String(),
      'durationMinutes': durationMinutes,
      if (password != null && password.isNotEmpty) 'password': password,
      'waitingRoomEnabled': waitingRoomEnabled,
      'watermarkEnabled': watermarkEnabled,
      if (recurrence != null && recurrence.isNotEmpty) 'recurrence': recurrence,
      'loginRequired': true,
      'usePmi': usePmi,
    });
    return Meeting.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<Meeting> getById(int id) async {
    final data = await _api.get('/meetings/$id');
    return Meeting.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 按会议号 / 邀请码查会议（输入会议号加入时用，可提前展示会议信息）
  Future<Meeting> getByNo(String meetingNo) async {
    final data = await _api.get('/meetings/by-no/$meetingNo');
    return Meeting.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 加入会议（REST 校验入口）。成功后还需要连 SignalR 调用 JoinRoom。
  Future<JoinOutcome> join(String meetingNo, {String? password}) async {
    final data = await _api.post('/meetings/join', data: {
      'meetingNo': meetingNo,
      if (password != null && password.isNotEmpty) 'password': password,
    });
    return JoinOutcome.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<void> leave(int meetingId) async {
    await _api.post('/meetings/$meetingId/leave');
  }

  /// 开始预约会议（主持人）
  Future<Meeting> start(int meetingId) async {
    final data = await _api.post('/meetings/$meetingId/start');
    return Meeting.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<List<Participant>> participants(int meetingId) async {
    final data = await _api.get('/meetings/$meetingId/participants');
    final list = (data as List?) ?? const [];
    return list.map((e) => Participant.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<List<ChatMessage>> messages(int meetingId) async {
    final data = await _api.get('/meetings/$meetingId/messages');
    final list = (data as List?) ?? const [];
    return list.map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<List<Poll>> polls(int meetingId) async {
    final data = await _api.get('/meetings/$meetingId/polls');
    final list = (data as List?) ?? const [];
    return list.map((e) => Poll.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<void> delete(int meetingId) async {
    await _api.delete('/meetings/$meetingId');
  }

  /// 上传聊天附件（图片/文件），返回可公网访问的 URL。
  /// 支持的类型由后端白名单决定（图片、pdf、office、zip、音视频等）。
  Future<UploadedFile> uploadFile(File file) async {
    final data = await _api.upload('/files/upload', file);
    return UploadedFile.fromJson((data as Map).cast<String, dynamic>());
  }

  // ==================== TRTC ====================

  /// 服务端 TRTC 配置。enabled=false 表示服务端未填写 SdkAppId/SecretKey，
  /// 此时音视频与屏幕共享都不可用，界面上必须明确提示，而不是让用户对着黑屏猜。
  Future<RtcConfig> rtcConfig() async {
    final data = await _api.get('/rtc/config');
    return RtcConfig.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 为当前登录用户签发 userSig
  Future<RtcUserSig> rtcUserSig() async {
    final data = await _api.get('/rtc/usersig');
    return RtcUserSig.fromJson((data as Map).cast<String, dynamic>());
  }
}
