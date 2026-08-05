/// The app's own deterministic mutation-timeout wording: the Rust-side
/// `MUTATION_TIMEOUT_MESSAGE`. This is the only error where a failed write
/// may still be landing in its background tail. [`isMutationTimeout`] and
/// the `actionFailureMessage` timeout line both match exactly this wording
/// because it gates
/// behavior (keeping a suppression or optimistic marker armed): third-party
/// error text that merely contains "timeout" (reqwest / matrix-sdk English
/// wording, server response bodies) is a confirmed failure with no tail.
const _mutationTimeoutWording = '操作超时，请稍后查看最终状态。';

/// Whether [error] is one of the app's own deterministic mutation
/// timeouts — the only case where the write may still be landing in its
/// background tail. Shared by the pages that keep their optimistic
/// marker/suppression armed on a timeout but restore it on a confirmed
/// failure (mute, unread). Do NOT widen this to a loose "timeout"
/// substring match: [actionFailureMessage] gates its timeout line on the
/// same exact wording, and a loose match here would misclassify confirmed
/// third-party failures as "may still land".
bool isMutationTimeout(Object error) {
  final message = '$error';
  return message.contains(_mutationTimeoutWording);
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
  // Only the app's own deterministic mutation-timeout wording maps to the
  // timeout line — same source as [isMutationTimeout], one constant keeps
  // the two in sync. Third-party text that merely contains "timeout"
  // (reqwest / matrix-sdk English wording, server response bodies) is a
  // confirmed failure with no background tail: mapping it to the timeout
  // line would imply "may have landed" and nudge the user to resend,
  // contradicting [isMutationTimeout].
  final timedOut = message.contains(_mutationTimeoutWording);
  return timedOut ? _mutationTimeoutWording : '操作失败: $error';
}
