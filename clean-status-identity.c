#include "git-compat-util.h"
#include "clean-status-identity.h"

int clean_status_identity_from_stat(struct clean_status_identity *identity,
				    const struct stat *st)
{
	memset(identity, 0, sizeof(*identity));
	if (!S_ISREG(st->st_mode) || st->st_nlink != 1)
		return -1;
	path_stat_identity_init(&identity->stat, st);
	return 0;
}

int clean_status_identity_is_durable(void)
{
#ifdef __APPLE__
	return 1;
#else
	return 0;
#endif
}

int clean_status_identity_equal(const struct clean_status_identity *a,
				const struct clean_status_identity *b)
{
	return path_stat_identity_equal(&a->stat, &b->stat);
}
