/// The app's own deterministic mutation-timeout wordings: the Rust-side
/// `MUTATION_TIMEOUT_MESSAGE` and the other bounded calls. These are the
/// ONLY errors where a failed write may still be landing in its background
/// tail. [`isMutationTimeout`] matches exactly these because it gates
/// behavior (keeping a suppression or optimistic marker armed): third-party
/// error text that merely contains "timeout" (reqwest / matrix-sdk English
/// wording, server response bodies) is a confirmed failure with no tail.
const List<String> _timeoutWordings = [
  '操作超时，请稍后查看最终状态。',
  '操作超时，请重试。',
  '连接超时，请检查网络或服务器地址',
  '同步超时（10 秒），请检查网络连接与服务器地址。',
  '上传超时，请重试。',
  '加载置顶消息超时。',
  '加载置顶事件超时。',
  '发送已读回执超时。',
];

/// Whether [error] is one of the app's own deterministic mutation
/// timeouts — the only case where the write may still be landing in its
/// background tail. Shared by the pages that keep their optimistic
/// marker/suppression armed on a timeout but restore it on a confirmed
/// failure (mute, unread). Do NOT widen this to a loose "timeout"
/// substring match: that is fine for wording only (see
/// [actionFailureMessage]) but would misclassify confirmed third-party
/// failures as "may still land".
bool isMutationTimeout(Object error) {
  final message = '$error';
  return _timeoutWordings.any(message.contains);
}

/// Map a failed write's error to the unified wording (timeout vs plain
/// failure, partial-success passthrough). Shared by every page that
/// surfaces write failures, so the timeout mapping and the partial-success
/// keyword list stay in one place (adjusting them once here keeps the
/// wording discipline across the app).
String actionFailureMessage(Object error) {
  final message = '$error';
  // Partially-succeeded outcomes (the primary write landed, a secondary
  // cleanup keeps running or failed) are not plain failures: pass their
  // wording through without the "操作失败" prefix, which would contradict
  // the message ("已读回执已发送；…仍在后台执行", "未读标记已清除，但已读
  // 回执发送失败: …", "空间名称已更新，但主题更新失败: …", "已加入空间，
  // 但设置空间父级失败: …"). Checked before the timeout mapping: the
  // partial-success wording must not be collapsed into the generic timeout
  // line (it would hide which side actually succeeded).
  if (message.contains('已发送') ||
      message.contains('已清除') ||
      message.contains('已更新') ||
      message.contains('已加入空间') ||
      message.contains('已移除') ||
      // "…已在后台进行" marks a partial-success (the clear side is still
      // running server-side while the receipt failed): pass it through.
      message.contains('已在后台进行') ||
      // "头像已上传，但应用失败…" is a partial-success too: the upload
      // landed, only the follow-up failed — the passthrough must not be
      // collapsed into the timeout line by the "请求超时" wording inside.
      message.contains('已上传') ||
      // "…仍在后台执行" marks a partial-success (the primary write landed
      // or is still running): pass it through — the generic timeout line
      // would hide which side succeeded.
      message.contains('仍在后台执行')) {
    return message;
  }
  // Wording-only wide matching is fine here (a misjudged word costs
  // nothing behaviorally); keep the deterministic app wordings and the
  // third-party English forms both mapped to the timeout line.
  final timedOut =
      message.contains('超时') ||
      message.toLowerCase().contains('timed out') ||
      message.toLowerCase().contains('timeout');
  return timedOut ? '操作超时，请稍后刷新确认最终状态' : '操作失败: $error';
}
