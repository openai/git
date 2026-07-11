#include "unit-test.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "dir.h"
#include "read-cache-ll.h"
#include "strbuf.h"
#include "wrapper.h"

void test_clean_status_index__binds_the_parsed_source(void)
{
	const char *tmp = getenv("TMPDIR");
	char *worktree = xstrfmt("%s/status-source.XXXXXX",
				 tmp ? tmp : "/tmp");
	struct index_state istate = { 0 };
	struct strbuf path = STRBUF_INIT, replacement = STRBUF_INIT;
	struct strbuf cleanup = STRBUF_INIT;
	struct stat original, current;

	cl_assert(mkdtemp(worktree) != NULL);
	strbuf_addf(&path, "%s/index", worktree);
	strbuf_addf(&replacement, "%s/replacement", worktree);
	write_file(path.buf, "original");
	write_file(replacement.buf, "replacement");
	cl_assert_equal_i(stat(path.buf, &original), 0);
	clean_status_get_state(&istate);
	clean_status_record_source_identity(&istate, &original);
	cl_assert(clean_status_verify_null_index(&istate, &original));

	cl_assert_equal_i(rename(replacement.buf, path.buf), 0);
	cl_assert_equal_i(stat(path.buf, &current), 0);
	if (clean_status_identity_is_durable())
		cl_assert(!clean_status_verify_null_index(&istate, &current));
	else
		cl_assert(clean_status_verify_null_index(&istate, &current));

	clean_status_release(&istate);
	strbuf_addstr(&cleanup, worktree);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	strbuf_release(&replacement);
	strbuf_release(&path);
	free(worktree);
}
