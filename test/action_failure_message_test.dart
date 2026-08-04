import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/action_failure_message.dart';

void main() {
  test('only a queued mutation timeout keeps optimistic state armed', () {
    expect(isMutationTimeout('操作超时，请稍后查看最终状态。'), isTrue);
    expect(isMutationTimeout('操作超时，请重试。'), isFalse);
    expect(isMutationTimeout('上传超时，请重试。'), isFalse);
    expect(isMutationTimeout('加载置顶消息超时。'), isFalse);
  });
}
