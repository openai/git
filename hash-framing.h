#ifndef HASH_FRAMING_H
#define HASH_FRAMING_H

#include "hash.h"

static inline void hash_length_delimited(struct git_hash_ctx *ctx,
					 const void *data, size_t len)
{
	uint32_t size;

	if (len > UINT32_MAX)
		BUG("length-delimited hash input too long");
	put_be32(&size, len);
	git_hash_update(ctx, &size, sizeof(size));
	if (len)
		git_hash_update(ctx, data, len);
}

static inline void hash_optional_cstring(struct git_hash_ctx *ctx,
					 const char *value)
{
	static const unsigned char missing = 0;

	if (value)
		hash_length_delimited(ctx, value, strlen(value));
	else
		hash_length_delimited(ctx, &missing, sizeof(missing));
}

#endif /* HASH_FRAMING_H */
