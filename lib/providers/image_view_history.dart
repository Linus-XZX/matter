import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef ImageViewScope = ({String account, String room});

class ImageViewHistory extends Notifier<List<String>> {
  ImageViewHistory(this.scope);
  final ImageViewScope scope;
  Future<void> _saving = Future.value();
  late Future<void> _restoring;
  List<String> _restoredIds = const [];
  String get _key =>
      'chat_image_views:${jsonEncode([scope.account, scope.room])}';

  @override
  List<String> build() {
    _restoring = _restore();
    unawaited(_restoring);
    return const [];
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_key) ?? const <String>[];
      _restoredIds = saved;
      if (!ref.mounted) return;
      final current = state.toSet();
      state = _bounded([
        ...saved.where((id) => !current.contains(id)),
        ...state,
      ]);
    } catch (error) {
      debugPrint('restore image viewing history failed: $error');
    }
  }

  List<String> _bounded(List<String> ids) =>
      List.unmodifiable(ids.length > 500 ? ids.sublist(ids.length - 500) : ids);

  Future<void> viewed(String id) {
    if (!ref.mounted || state.isNotEmpty && state.last == id) return _saving;
    state = _bounded([...state.where((previous) => previous != id), id]);
    final snapshot = state;
    _saving = _saving.then((_) async {
      try {
        await _restoring;
        final prefs = await SharedPreferences.getInstance();
        final current = snapshot.toSet();
        await prefs.setStringList(
          _key,
          _bounded([
            ..._restoredIds.where((id) => !current.contains(id)),
            ...snapshot,
          ]),
        );
      } catch (error) {
        debugPrint('save image viewing history failed: $error');
      }
    });
    return _saving;
  }
}

final imageViewHistoryProvider =
    NotifierProvider.family<ImageViewHistory, List<String>, ImageViewScope>(
      ImageViewHistory.new,
    );
