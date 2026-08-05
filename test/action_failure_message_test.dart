import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/action_failure_message.dart';

void main() {
  test('only a queued mutation timeout keeps optimistic state armed', () {
    expect(isMutationTimeout('操作超时，请稍后查看最终状态。'), isTrue);
    expect(isMutationTimeout('操作超时，请重试。'), isFalse);
    expect(isMutationTimeout('上传超时，请重试。'), isFalse);
    expect(isMutationTimeout('加载置顶消息超时。'), isFalse);
  });

  test('actionFailureMessage maps only the deterministic mutation timeout '
      'to the timeout line', () {
    // The one case where the write may still be landing: the unified
    // timeout wording (same source as isMutationTimeout, so both stay in
    // sync) — not the raw error, not a "操作失败" prefix.
    expect(actionFailureMessage('操作超时，请稍后查看最终状态。'), '操作超时，请稍后查看最终状态。');
    expect(actionFailureMessage('前缀 操作超时，请稍后查看最终状态。 后缀'), '操作超时，请稍后查看最终状态。');
  });

  test('actionFailureMessage treats third-party timeout text as a confirmed '
      'failure', () {
    // Merely containing "timeout" (Chinese or English, SDK/server wording)
    // is a confirmed failure with no background tail — the timeout line
    // would imply "may have landed" and contradict isMutationTimeout.
    expect(actionFailureMessage('上传超时，请重试。'), '操作失败: 上传超时，请重试。');
    expect(actionFailureMessage('请求超时，请稍后重试'), '操作失败: 请求超时，请稍后重试');
    expect(
      actionFailureMessage('reqwest request timed out'),
      '操作失败: reqwest request timed out',
    );
    expect(
      actionFailureMessage('mute failed: timeout'),
      '操作失败: mute failed: timeout',
    );
    expect(actionFailureMessage('超时'), '操作失败: 超时');
  });

  test('actionFailureMessage keeps plain failures and partial-success '
      'passthrough', () {
    expect(actionFailureMessage('服务器拒绝'), '操作失败: 服务器拒绝');
    // Partial successes keep their own wording (the primary write landed);
    // none of them contain the deterministic mutation-timeout wording.
    expect(
      actionFailureMessage('未读标记已清除，但已读回执发送失败: timeout'),
      '未读标记已清除，但已读回执发送失败: timeout',
    );
    expect(actionFailureMessage('头像已上传，但应用失败: 请求超时'), '头像已上传，但应用失败: 请求超时');
  });
}
