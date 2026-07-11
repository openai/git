#ifndef SEMANTIC_VERIFY_INTERNAL_H
#define SEMANTIC_VERIFY_INTERNAL_H

#include "statinfo.h"

#ifdef __linux__
#include <sys/syscall.h>
#if !defined(SYS_openat2) && defined(__NR_openat2)
#define SYS_openat2 __NR_openat2
#elif !defined(SYS_openat2) && \
	(defined(__x86_64__) || defined(__i386__))
#define SYS_openat2 437
#endif
#endif

#if defined(__APPLE__) && defined(O_NONBLOCK) && \
	defined(O_NOFOLLOW) && defined(O_DIRECTORY) && \
	defined(AT_SYMLINK_NOFOLLOW)
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 1
#elif defined(__linux__) && defined(SYS_openat2) && \
	defined(O_CLOEXEC) && defined(O_NONBLOCK) && \
	defined(O_NOFOLLOW) && defined(O_DIRECTORY) && \
	defined(AT_SYMLINK_NOFOLLOW)
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 1
#else
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 0
#endif

struct repository;

struct semantic_verify_root {
	int fd;
	char *path;
	struct stat stat;
};

int semantic_verify_root_init(struct repository *repo,
			      struct semantic_verify_root **root_out);
void semantic_verify_root_clear(struct semantic_verify_root *root);

int semantic_verify_openat(int dirfd, const char *path, int flags);

#endif /* SEMANTIC_VERIFY_INTERNAL_H */
