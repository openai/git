#ifndef EXCLUDE_SOURCE_PROOF_H
#define EXCLUDE_SOURCE_PROOF_H

#if (defined(__APPLE__) || defined(__linux__)) && \
	defined(O_CLOEXEC) && defined(O_NONBLOCK) && \
	defined(O_NOFOLLOW) && defined(O_DIRECTORY) && \
	defined(AT_SYMLINK_NOFOLLOW)
#define EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN 1
#else
#define EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN 0
#endif

struct exclude_source_capture;
struct exclude_source_proof;
struct index_state;
struct stat;

typedef int (*exclude_source_open_parent_fn)(void *data, const char *path);

struct exclude_source_proof *exclude_source_proof_create(
	struct index_state *istate, void *open_data,
	exclude_source_open_parent_fn open_parent);
struct exclude_source_capture *exclude_source_capture_begin(
	struct exclude_source_proof *proof, const char *path,
	int nofollow);
int exclude_source_capture_open(struct exclude_source_capture *capture);
int exclude_source_capture_absent(struct exclude_source_capture *capture);
void exclude_source_capture_record(
	struct exclude_source_capture *capture,
	int source_fd,
	const struct stat *source_stat,
	const void *buf, size_t size);
void exclude_source_capture_error(struct exclude_source_capture *capture);
void exclude_source_capture_release(struct exclude_source_capture *capture);
int exclude_source_proof_validate(struct exclude_source_proof *proof);
void exclude_source_proof_release(struct exclude_source_proof *proof);

#endif /* EXCLUDE_SOURCE_PROOF_H */
