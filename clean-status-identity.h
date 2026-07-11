#ifndef CLEAN_STATUS_IDENTITY_H
#define CLEAN_STATUS_IDENTITY_H

#include "path-namespace.h"

struct stat;

struct clean_status_identity {
	struct path_stat_identity stat;
};

int clean_status_identity_from_stat(struct clean_status_identity *identity,
				    const struct stat *st);
int clean_status_identity_is_durable(void);
int clean_status_identity_equal(const struct clean_status_identity *a,
				const struct clean_status_identity *b);

#endif /* CLEAN_STATUS_IDENTITY_H */
