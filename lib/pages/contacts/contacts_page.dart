import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';

class ContactsPage extends ConsumerWidget {
  const ContactsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            pinned: true,
            title: Text(
              '通讯录',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.onBackground,
                letterSpacing: -0.5,
              ),
            ),
            backgroundColor: AppColors.background,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                ),
                child: const Row(
                  children: [
                    SizedBox(width: 12),
                    Icon(
                      Icons.search_rounded,
                      color: AppColors.onSurfaceVariant,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        style: TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: '搜索联系人',
                          hintStyle: TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 15,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
          contactsAsync.when(
            data: (contacts) {
              return SliverList.separated(
                itemCount: contacts.length,
                separatorBuilder: (context, index) => const Divider(
                  color: AppColors.surfaceVariant,
                  thickness: 0.5,
                  indent: 82,
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final contact = contacts[index];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        AppAvatar(
                          fallback: contact.name,
                          size: 48,
                          radius: AppRadii.content,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                contact.name,
                                style: const TextStyle(
                                  color: AppColors.onBackground,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                contact.status,
                                style: const TextStyle(
                                  color: AppColors.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.message_rounded,
                            color: AppColors.onSurfaceVariant,
                            size: 20,
                          ),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  );
                },
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    '加载失败: $err',
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
),
          const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
         ],
       ),
     );
   }
 }
