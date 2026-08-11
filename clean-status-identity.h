#ifndef CLEAN_STATUS_IDENTITY_H
#define CLEAN_STATUS_IDENTITY_H

#include "path-namespace.h"

struct strbuf;
struct stat;

struct clean_status_identity {
	struct path_stat_identity stat;
};

#define CLEAN_STATUS_IDENTITY_SIZE \
	(PATH_STAT_IDENTITY_FIELDS * sizeof(uint64_t))

int clean_status_identity_from_stat(struct clean_status_identity *identity,
				    const struct stat *st);
int clean_status_identity_is_durable(void);
int clean_status_identity_equal(const struct clean_status_identity *a,
				const struct clean_status_identity *b);
void clean_status_identity_write(struct strbuf *out,
				 const struct clean_status_identity *identity);
int clean_status_identity_read(const unsigned char **p,
			       const unsigned char *end,
			       struct clean_status_identity *identity);

#endif /* CLEAN_STATUS_IDENTITY_H */
