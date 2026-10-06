import 'dart:io';

import '../core/api_client.dart';
import '../models/models.dart';

/// 认证与个人资料（对应后端 AuthController / UsersController）
class AuthService {
  AuthService(this._api);

  final ApiClient _api;

  /// 注册。成功后后端直接返回 token，无需再登录一次。
  Future<AuthResult> register({
    required String username,
    required String password,
    required String nickname,
    String? department,
    String? email,
  }) async {
    final data = await _api.post('/auth/register', auth: false, data: {
      'username': username,
      'password': password,
      'nickname': nickname,
      if (department != null && department.isNotEmpty) 'department': department,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    return AuthResult.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<AuthResult> login(String username, String password) async {
    final data = await _api.post('/auth/login', auth: false, data: {
      'username': username,
      'password': password,
    });
    return AuthResult.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 校验本地 token 是否仍然有效，并拿到最新用户信息
  Future<AppUser> me() async {
    final data = await _api.get('/auth/me');
    return AppUser.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<AppUser> updateProfile({
    String? nickname,
    String? department,
    String? email,
  }) async {
    final data = await _api.put('/users/me', data: {
      if (nickname != null) 'nickname': nickname,
      if (department != null) 'department': department,
      if (email != null) 'email': email,
    });
    return AppUser.fromJson((data as Map).cast<String, dynamic>());
  }

  /// 上传头像，返回新的头像 URL
  Future<String?> uploadAvatar(File file) async {
    final data = await _api.upload('/users/me/avatar', file);
    if (data is Map) return data['avatarUrl'] as String?;
    return null;
  }

  /// 按昵称 / 用户名 / PMI 搜索用户（私聊选人、按 PMI 参会）
  Future<List<AppUser>> search(String q) async {
    final data = await _api.get('/users/search', query: {'q': q});
    final list = (data as List?) ?? const [];
    return list.map((e) => AppUser.fromJson((e as Map).cast<String, dynamic>())).toList();
  }
}
