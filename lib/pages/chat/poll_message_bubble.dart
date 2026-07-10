import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

typedef PollVoteCallback = Future<void> Function(List<String> answerIds);
typedef PollEndCallback = Future<void> Function();
typedef PollRefreshCallback = Future<void> Function();

/// Renders a poll and keeps vote/end operations serial and optimistic.
class PollMessageBubble extends ConsumerStatefulWidget {
  final String roomId;
  final String pollStartEventId;
  final rust.PollInfo poll;
  final bool isMe;
  final Widget metadata;
  final double maxWidth;
  final PollVoteCallback? onVote;
  final PollEndCallback? onEnd;
  final PollRefreshCallback? onRefresh;

  const PollMessageBubble({
    super.key,
    required this.roomId,
    required this.pollStartEventId,
    required this.poll,
    required this.isMe,
    required this.metadata,
    this.maxWidth = 280,
    this.onVote,
    this.onEnd,
    this.onRefresh,
  });

  @override
  ConsumerState<PollMessageBubble> createState() => _PollMessageBubbleState();
}

class _PollMessageBubbleState extends ConsumerState<PollMessageBubble> {
  late Set<String> _selected;
  bool _submitting = false;
  bool _endedLocally = false;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.of(widget.poll.myAnswerIds);
  }

  @override
  void didUpdateWidget(covariant PollMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_submitting &&
        (oldWidget.pollStartEventId != widget.pollStartEventId ||
            !_setsEqual(
              oldWidget.poll.myAnswerIds.toSet(),
              widget.poll.myAnswerIds.toSet(),
            ))) {
      _selected = Set<String>.of(widget.poll.myAnswerIds);
    }
    if (oldWidget.pollStartEventId != widget.pollStartEventId) {
      _endedLocally = widget.poll.ended;
    } else if (widget.poll.ended) {
      _endedLocally = true;
    }
  }

  int _countFor(String id) {
    for (final result in widget.poll.results) {
      if (result.answerId == id) return result.count;
    }
    return 0;
  }

  Future<void> _vote(String answerId) async {
    if (_submitting || widget.poll.ended || _endedLocally) return;
    final previous = Set<String>.of(_selected);
    final next = Set<String>.of(previous);
    if (widget.poll.maxSelections > 1) {
      if (next.contains(answerId)) {
        next.remove(answerId);
      } else if (next.length < widget.poll.maxSelections) {
        next.add(answerId);
      } else {
        next
          ..remove(next.first)
          ..add(answerId);
      }
    } else {
      next
        ..clear()
        ..add(answerId);
    }
    if (next.isEmpty || _setsEqual(next, previous)) return;

    setState(() {
      _selected = next;
      _submitting = true;
    });
    try {
      if (widget.onVote != null) {
        await widget.onVote!(next.toList());
      } else {
        await rust.sendPollResponse(
          roomId: widget.roomId,
          pollStartEventId: widget.pollStartEventId,
          answerIds: next.toList(),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _selected = previous);
      _showError('投票失败: $error');
      return;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    await _refreshBestEffort();
  }

  Future<void> _endPoll() async {
    if (_submitting || widget.poll.ended || _endedLocally || !widget.isMe) {
      return;
    }
    setState(() => _submitting = true);
    var succeeded = false;
    try {
      if (widget.onEnd != null) {
        await widget.onEnd!();
      } else {
        await rust.endPoll(
          roomId: widget.roomId,
          pollStartEventId: widget.pollStartEventId,
        );
      }
      succeeded = true;
      if (mounted) setState(() => _endedLocally = true);
    } catch (error) {
      if (mounted) _showError('结束投票失败: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (succeeded) await _refreshBestEffort();
  }

  Future<void> _refreshBestEffort() async {
    try {
      if (widget.onRefresh != null) {
        await widget.onRefresh!();
      } else {
        await refreshMessages(ref, widget.roomId);
      }
    } catch (_) {
      // Sync will eventually reconcile a successfully sent response.
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  bool _setsEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final ended = poll.ended || _endedLocally;
    final reveal = poll.disclosed || ended;
    final multi = poll.maxSelections > 1;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.content),
        child: Stack(
          children: [
            Material(
              color: widget.isMe
                  ? AppColors.primary.withValues(alpha: 0.18)
                  : AppColors.surfaceVariant,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.poll_rounded,
                          color: AppColors.primary,
                          size: 18,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '投票',
                          style: TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      poll.question,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final answer in poll.answers)
                      _PollAnswerRow(
                        answer: answer,
                        multi: multi,
                        selected: _selected.contains(answer.id),
                        count: _countFor(answer.id),
                        totalVoters: poll.totalVoters,
                        reveal: reveal,
                        enabled: !ended && !_submitting,
                        onTap: () => _vote(answer.id),
                      ),
                    if (reveal) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${poll.totalVoters} 人参与${ended ? ' · 已结束' : ''}',
                        style: const TextStyle(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ] else
                      const SizedBox(height: 4),
                    if (widget.isMe && !ended) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _submitting ? null : _endPoll,
                          icon: const Icon(
                            Icons.stop_circle_outlined,
                            size: 16,
                          ),
                          label: const Text('结束投票'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_submitting)
              const Positioned(
                right: 10,
                top: 10,
                child: SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            widget.metadata,
          ],
        ),
      ),
    );
  }
}

class _PollAnswerRow extends StatelessWidget {
  final rust.PollAnswerInfo answer;
  final bool multi;
  final bool selected;
  final int count;
  final int totalVoters;
  final bool reveal;
  final bool enabled;
  final VoidCallback onTap;

  const _PollAnswerRow({
    required this.answer,
    required this.multi,
    required this.selected,
    required this.count,
    required this.totalVoters,
    required this.reveal,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = totalVoters > 0 && reveal
        ? (count / totalVoters).clamp(0.0, 1.0)
        : 0.0;
    final control = Icon(
      multi
          ? selected
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded
          : selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
      size: 18,
      color: AppColors.primary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (reveal)
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction,
                  child: Container(
                    height: 32,
                    color: AppColors.primary.withValues(
                      alpha: selected ? 0.28 : 0.16,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(
                  children: [
                    control,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        answer.text,
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (reveal)
                      Text(
                        '$count',
                        style: const TextStyle(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
