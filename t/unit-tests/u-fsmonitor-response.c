#include "unit-test.h"

#include "fsmonitor.h"

static void check_response(const void *data, size_t len,
			   enum fsmonitor_query_outcome expected,
			   const char *token, const void *paths,
			   size_t paths_len)
{
	struct fsmonitor_query_result result = FSMONITOR_QUERY_RESULT_INIT;
	struct strbuf raw = STRBUF_INIT;

	strbuf_add(&raw, data, len);
	cl_assert_equal_i(fsmonitor_parse_builtin_response(&raw, &result),
			  expected);
	cl_assert_equal_i(result.outcome, expected);
	cl_assert_equal_s(result.token.buf, token);
	cl_assert_equal_i(result.paths.len, paths_len);
	cl_assert(!paths_len || !memcmp(result.paths.buf, paths, paths_len));

	fsmonitor_query_result_release(&result);
	strbuf_release(&raw);
}

static void check_malformed(const void *data, size_t len)
{
	check_response(data, len, FSMONITOR_QUERY_ERROR, "", NULL, 0);
}

void test_fsmonitor_response__rejects_malformed_framing(void)
{
	static const char missing_nul[] = "builtin:1";
	static const char empty_token[] = "\0";
	static const char non_builtin[] = "other:1\0";
	static const char unterminated_path[] = "builtin:1\0path";
	static const char empty_path[] = "builtin:1\0\0";
	static const char absolute_path[] = "builtin:1\0/absolute\0";
	static const char parent_path[] = "builtin:1\0../outside\0";
	static const char embedded_parent[] =
		"builtin:1\0dir/../tracked\0";
	static const char dot_path[] = "builtin:1\0./tracked\0";
	static const char repeated_separator[] =
		"builtin:1\0dir//tracked\0";
	static const char drive_path[] = "builtin:1\0C:/absolute\0";
	static const char backslash_path[] = "builtin:1\0\\absolute\0";
	struct strbuf overlong = STRBUF_INIT;

	check_malformed("", 0);
	check_malformed(missing_nul, sizeof(missing_nul) - 1);
	check_malformed(empty_token, sizeof(empty_token) - 1);
	check_malformed(non_builtin, sizeof(non_builtin) - 1);
	check_malformed(unterminated_path, sizeof(unterminated_path) - 1);
	check_malformed(empty_path, sizeof(empty_path) - 1);
	check_malformed(absolute_path, sizeof(absolute_path) - 1);
	check_malformed(parent_path, sizeof(parent_path) - 1);
	check_malformed(embedded_parent, sizeof(embedded_parent) - 1);
	check_malformed(dot_path, sizeof(dot_path) - 1);
	check_malformed(repeated_separator,
			sizeof(repeated_separator) - 1);
	if (has_dos_drive_prefix(drive_path + sizeof("builtin:1")))
		check_malformed(drive_path, sizeof(drive_path) - 1);
	if (is_dir_sep('\\'))
		check_malformed(backslash_path, sizeof(backslash_path) - 1);

	strbuf_addstr(&overlong, "builtin:");
	strbuf_addchars(&overlong, 'x', 4096);
	strbuf_addch(&overlong, '\0');
	check_malformed(overlong.buf, overlong.len);
	strbuf_release(&overlong);
}

void test_fsmonitor_response__accepts_valid_builtin_responses(void)
{
	static const char delta[] = "builtin:2\0a\0dir/file\0dir/\0";
	static const char global[] = "builtin:3\0//\0";
	static const char trivial[] = "builtin:4\0/\0";

	check_response(delta, sizeof(delta) - 1, FSMONITOR_QUERY_DELTA,
		       "builtin:2", delta + sizeof("builtin:2"),
		       sizeof(delta) - 1 - sizeof("builtin:2"));
	check_response(global, sizeof(global) - 1, FSMONITOR_QUERY_DELTA,
		       "builtin:3", global + sizeof("builtin:3"),
		       sizeof(global) - 1 - sizeof("builtin:3"));
	check_response(trivial, sizeof(trivial) - 1, FSMONITOR_QUERY_TRIVIAL,
		       "builtin:4", NULL, 0);
}
