#include "git-compat-util.h"
#include "clean-status-identity.h"
#include "strbuf.h"

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

void clean_status_identity_write(struct strbuf *out,
				 const struct clean_status_identity *identity)
{
	uint64_t value;
	size_t i;

	for (i = 0; i < ARRAY_SIZE(identity->stat.fields); i++) {
		put_be64(&value, identity->stat.fields[i]);
		strbuf_add(out, &value, sizeof(value));
	}
}

int clean_status_identity_read(const unsigned char **p,
			       const unsigned char *end,
			       struct clean_status_identity *identity)
{
	size_t i;

	memset(identity, 0, sizeof(*identity));
	for (i = 0; i < ARRAY_SIZE(identity->stat.fields); i++) {
		if ((size_t)(end - *p) < sizeof(uint64_t))
			return -1;
		identity->stat.fields[i] = get_be64(*p);
		*p += sizeof(uint64_t);
	}
	return 0;
}
