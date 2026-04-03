import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kore_chat/utils/custom_toast.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_call_service.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_index.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController(
    text: 'lunagariyakrunal26@gmail.com',
  );
  final _passwordController = TextEditingController(
    text: 'pawanputra',
  );

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _rememberMe = false;
  String _appVersion = '';

  static const String _prefEmail = 'saved_email';
  static const String _prefPassword = 'saved_password';
  static const String _prefRememberMe = 'remember_me';

  @override
  void initState() {
    super.initState();
    _loadRememberedCredentials();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = "v${info.version}";
    });
  }

  // ── SharedPreferences helpers ──────────────────────────────────

  Future<void> _loadRememberedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final rememberMe = prefs.getBool(_prefRememberMe) ?? false;
    if (rememberMe) {
      setState(() {
        _rememberMe = true;
        _emailController.text = prefs.getString(_prefEmail) ?? '';
        _passwordController.text = prefs.getString(_prefPassword) ?? '';
      });
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefRememberMe, _rememberMe);
    if (_rememberMe) {
      await prefs.setString(_prefEmail, _emailController.text.trim());
      await prefs.setString(_prefPassword, _passwordController.text);
    } else {
      // Clear saved credentials when remember me is turned off
      await prefs.remove(_prefEmail);
      await prefs.remove(_prefPassword);
    }
  }

  // ── Login handler ──────────────────────────────────────────────

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await ApiCall.post(
        'v1/auth/login',
        data: {
          'email': _emailController.text.trim(),
          'password': _passwordController.text,
        },
      );

      if (response['success'] == true) {
        final token = response['data']['token'] as String;
        final user = response['data']['user'] as Map<String, dynamic>;
        final userId = (user['userId'] as num?)?.toInt() ?? 0;
        final userName = (user['userName'] as String?) ?? '';
        final email = (user['email'] as String?) ?? '';

        // 1. Set token in ApiCall service
        ApiCall.setAuthToken(token);
        SocketIndex.connectSocket(token, userId: userId);

        // 2. Persist to SharedPreferences so splash can auto-login next time
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', token);
        await prefs.setInt('user_id', userId);
        await prefs.setString('user_name', userName);
        await prefs.setString('user_email', email);

        try {
          final fcmToken = NotificationService().fcmToken;
          final voipToken = NotificationService().voipToken;

          if (fcmToken != null && fcmToken.isNotEmpty) {
            await ApiCall.post(
              'v1/user/user-device',
              data: {
                'userId': userId,
                'deviceType': Platform.isIOS ? 'ios' : 'android',
                'fcmToken': fcmToken,
                'voIpToken': voipToken,
              },
            );
          }
        } catch (_) {
          CustomToast.showError(context, "Error in send token to server");
        }

        // 3. Save credentials if remember me is on
        await _saveCredentials();

        // 4. Navigate to home, clear back stack
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (_) => HomeScreen(userId: userId, userName: userName),
            ),
            (_) => false,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        CustomToast.showError(context, e.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Sync status bar style with theme
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 60),
                _buildLogo(isDark),
                const SizedBox(height: 52),
                _buildHeader(isDark),
                const SizedBox(height: 40),
                _buildFormCard(isDark),
                const SizedBox(height: 28),
                _buildLoginButton(),
                const SizedBox(height: 16),
                // _buildForgotPassword(isDark),
                const SizedBox(height: 48),
                _buildFooter(isDark),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Logo ───────────────────────────────────────────────────────

  Widget _buildLogo(bool isDark) {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.redAccent, AppTheme.redDark],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppTheme.redAccent.withOpacity(0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.chat_bubble_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: 'KORE ',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  const TextSpan(
                    text: 'CIRCLE',
                    style: TextStyle(
                      color: AppTheme.redAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              'Business Messaging',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w400,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Header ─────────────────────────────────────────────────────

  Widget _buildHeader(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Welcome\nBack.',
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextPrimary
                : AppTheme.lightTextPrimary,
            fontSize: 44,
            fontWeight: FontWeight.w900,
            height: 1.1,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Sign in to continue to your workspace',
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
            fontSize: 15,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }

  // ── Form card ──────────────────────────────────────────────────

  Widget _buildFormCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.4)
                : Colors.black.withOpacity(0.06),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFieldLabel('Email Address', isDark),
            const SizedBox(height: 8),
            _buildEmailField(isDark),
            const SizedBox(height: 20),
            _buildFieldLabel('Password', isDark),
            const SizedBox(height: 8),
            _buildPasswordField(isDark),
            const SizedBox(height: 20),
            _buildRememberMe(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label, bool isDark) {
    return Text(
      label,
      style: TextStyle(
        color: isDark
            ? AppTheme.darkTextSecondary
            : AppTheme.lightTextSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildEmailField(bool isDark) {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      style: TextStyle(
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
        fontSize: 15,
      ),
      cursorColor: AppTheme.redAccent,
      decoration: InputDecoration(
        hintText: 'you@example.com',
        prefixIcon: Icon(
          Icons.mail_outline_rounded,
          color: isDark
              ? AppTheme.darkTextSecondary.withOpacity(0.6)
              : AppTheme.lightTextSecondary.withOpacity(0.7),
          size: 20,
        ),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Please enter your email';
        if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
          return 'Please enter a valid email';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField(bool isDark) {
    return TextFormField(
      controller: _passwordController,
      obscureText: !_isPasswordVisible,
      style: TextStyle(
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
        fontSize: 15,
      ),
      cursorColor: AppTheme.redAccent,
      decoration: InputDecoration(
        hintText: '• • • • • •',
        prefixIcon: Icon(
          Icons.lock_outline_rounded,
          color: isDark
              ? AppTheme.darkTextSecondary.withOpacity(0.6)
              : AppTheme.lightTextSecondary.withOpacity(0.7),
          size: 20,
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _isPasswordVisible
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            color: isDark
                ? AppTheme.darkTextSecondary.withOpacity(0.6)
                : AppTheme.lightTextSecondary.withOpacity(0.7),
            size: 20,
          ),
          onPressed: () =>
              setState(() => _isPasswordVisible = !_isPasswordVisible),
        ),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Please enter your password';
        return null;
      },
    );
  }

  Widget _buildRememberMe(bool isDark) {
    return GestureDetector(
      onTap: () => setState(() => _rememberMe = !_rememberMe),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _rememberMe ? AppTheme.redAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _rememberMe
                    ? AppTheme.redAccent
                    : (isDark
                          ? AppTheme.darkTextSecondary.withOpacity(0.4)
                          : AppTheme.lightTextSecondary.withOpacity(0.5)),
                width: 1.5,
              ),
            ),
            child: _rememberMe
                ? const Icon(Icons.check, color: Colors.white, size: 14)
                : null,
          ),
          const SizedBox(width: 10),
          Text(
            'Remember me',
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
          ),
          const Spacer(),
          Text(
            'Saves your credentials',
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.4)
                  : AppTheme.lightTextSecondary.withOpacity(0.5),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  // ── Login button ───────────────────────────────────────────────

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isLoading
                ? [AppTheme.redDark, AppTheme.redDark]
                : [AppTheme.redAccent, AppTheme.redDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: _isLoading
              ? []
              : [
                  BoxShadow(
                    color: AppTheme.redAccent.withOpacity(0.4),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _isLoading ? null : _handleLogin,
            borderRadius: BorderRadius.circular(16),
            splashColor: Colors.white.withOpacity(0.1),
            child: Center(
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Sign In',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Forgot password ────────────────────────────────────────────

  Widget _buildForgotPassword(bool isDark) {
    return Center(
      child: TextButton(
        onPressed: () {
          // TODO: Navigate to forgot password screen
        },
        child: Text(
          'Forgot Password?',
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ── Footer ─────────────────────────────────────────────────────

  Widget _buildFooter(bool isDark) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Divider(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.1),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'KORE MOBILES',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary.withOpacity(0.4)
                      : AppTheme.lightTextSecondary.withOpacity(0.5),
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Divider(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Kore Circle $_appVersion · Secure Business Messaging',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextSecondary.withOpacity(0.35)
                : AppTheme.lightTextSecondary.withOpacity(0.4),
            fontSize: 11,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
