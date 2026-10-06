import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../services/auth_service.dart';
import '../widgets/common.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _nickname = TextEditingController();
  final _department = TextEditingController();
  final _email = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _nickname.dispose();
    _department.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final session = context.read<Session>();
    try {
      final res = await context.read<AuthService>().register(
            username: _username.text.trim(),
            password: _password.text,
            nickname: _nickname.text.trim().isEmpty ? _username.text.trim() : _nickname.text.trim(),
            department: _department.text.trim(),
            email: _email.text.trim(),
          );
      await session.saveAuth(res.token, res.user);
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, '注册成功，已自动登录');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '注册失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注册账号')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: '用户名 *',
                  prefixIcon: Icon(Icons.person_outline),
                  helperText: '用于登录，注册后不可修改',
                ),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return '请输入用户名';
                  if (s.length < 3) return '用户名至少 3 位';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码 *',
                  prefixIcon: Icon(Icons.lock_outline),
                  helperText: '至少 6 位',
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return '请输入密码';
                  if (v.length < 6) return '密码至少 6 位';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认密码 *',
                  prefixIcon: Icon(Icons.lock_reset),
                ),
                validator: (v) => v != _password.text ? '两次输入的密码不一致' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _nickname,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  prefixIcon: Icon(Icons.badge_outlined),
                  helperText: '会议中显示的名字，留空则用用户名',
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _department,
                decoration: const InputDecoration(
                  labelText: '部门',
                  prefixIcon: Icon(Icons.apartment_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('注册并登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
