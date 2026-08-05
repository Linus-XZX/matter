const ignoredUsersCachePrefix = 'ignored_users_v1';

String ignoredUsersCacheKey(String userId) =>
    '${ignoredUsersCachePrefix}_$userId';
