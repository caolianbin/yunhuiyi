import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import '../models/models.dart';

/// 本地会话：token、当前用户、后端地址。
///
/// 后端地址也放在这里持久化，是为了让真机调试时不必为了换一个 IP 就重新打包。
class Session extends ChangeNotifier {
  static const _kToken = 'auth_token';
  static const _kUser = 'auth_user';
  static const _kBaseUrl = 'base_url';

  SharedPreferences? _prefs;

  String? _token;
  AppUser? _user;
  String _baseUrl = AppConfig.defaultBaseUrl;

  String? get token => _token;
  AppUser? get user => _user;
  String get baseUrl => _baseUrl;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty && _user != null;

  /// REST 根地址，如 http://192.168.1.5:5000/api
  String get apiBase => '$_baseUrl${AppConfig.apiPrefix}';

  /// SignalR Hub 完整地址
  String get hubUrl => '$_baseUrl${AppConfig.hubPath}';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _token = _prefs!.getString(_kToken);
    _baseUrl = _prefs!.getString(_kBaseUrl) ?? AppConfig.defaultBaseUrl;

    final rawUser = _prefs!.getString(_kUser);
    if (rawUser != null && rawUser.isNotEmpty) {
      try {
        _user = AppUser.fromJson(
            (jsonDecode(rawUser) as Map).cast<String, dynamic>());
      } catch (_) {
        _user = null;
      }
    }
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = _normalizeBaseUrl(url);
    await _prefs?.setString(_kBaseUrl, _baseUrl);
    notifyListeners();
  }

  /// 统一去掉结尾斜杠，避免拼出 //api
  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return AppConfig.defaultBaseUrl;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Future<void> saveAuth(String token, AppUser user) async {
    _token = token;
    _user = user;
    await _prefs?.setString(_kToken, token);
    await _prefs?.setString(_kUser, jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> updateUser(AppUser user) async {
    _user = user;
    await _prefs?.setString(_kUser, jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> clearAuth() async {
    _token = null;
    _user = null;
    await _prefs?.remove(_kToken);
    await _prefs?.remove(_kUser);
    notifyListeners();
  }
}
