#ifndef SEMANTIC_VERIFY_H
#define SEMANTIC_VERIFY_H

struct index_state;
struct semantic_verify_proof;

enum semantic_verify_kind {
	SEMANTIC_VERIFY_UNCHECKED = 0,
	SEMANTIC_VERIFY_SKIPPED,
	SEMANTIC_VERIFY_RAW_CLEAN,
	SEMANTIC_VERIFY_RAW_MODIFIED,
	SEMANTIC_VERIFY_SENSITIVE,
	SEMANTIC_VERIFY_STRUCTURAL,
	SEMANTIC_VERIFY_UNSTABLE,
	SEMANTIC_VERIFY_ERROR,
};

enum semantic_verify_result_flags {
	/* The clean result may receive persistent fsmonitor validity. */
	SEMANTIC_VERIFY_PERSISTABLE = (1u << 0),
};

struct semantic_verify_result {
	uint16_t error;
	uint8_t kind;
	uint8_t flags;
};

struct semantic_verify_stats {
	size_t cache_nr;
	size_t stat_updates_nr;
	size_t bytes_hashed;
	size_t raw_clean;
	size_t raw_modified;
	size_t sensitive;
	size_t structural;
	size_t skipped;
	size_t unstable;
	size_t errors;
	size_t hardlinks;
	unsigned int namespace_unstable;
};

/* Build a proof candidate without changing the index. */
int semantic_verify_prepare(struct index_state *istate,
			    struct semantic_verify_proof **proof_out);
int semantic_verify_root_is_stable(
	const struct semantic_verify_proof *proof);
void semantic_verify_proof_clear(struct semantic_verify_proof *proof);

/* Introspection used by the semantic verifier test helper. */
void semantic_verify_get_stats(const struct semantic_verify_proof *proof,
			       struct semantic_verify_stats *stats);
const struct semantic_verify_result *semantic_verify_result_at(
	const struct semantic_verify_proof *proof, size_t cache_pos);

#endif /* SEMANTIC_VERIFY_H */
