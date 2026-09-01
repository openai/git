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

static void check_worktree_event(
	const char *path, size_t worktree_len,
	int is_file, int is_directory,
	const void *expected, size_t expected_len)
{
	struct strbuf paths = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;

	fsmonitor_format_worktree_paths(
		&paths, path, worktree_len, is_file, is_directory);
	cl_assert_equal_i(paths.len, expected_len);
	cl_assert(!expected_len || !memcmp(paths.buf, expected, expected_len));

	strbuf_addstr(&response, "builtin:worktree");
	strbuf_addch(&response, '\0');
	strbuf_addbuf(&response, &paths);
	check_response(response.buf, response.len, FSMONITOR_QUERY_DELTA,
		       "builtin:worktree", expected, expected_len);

	strbuf_release(&response);
	strbuf_release(&paths);
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
	static const char stale_root[] = "/repo\0stale/path";
	static const char global_path[] = "//\0";
	static const char file_path[] = "tracked\0";
	static const char directory_path[] = "nested/\0";
	static const char both_paths[] = "merged\0merged/\0";
	static const char case_path[] = "Tracked\0";
	static const char nested_git[] =
		"builtin:12\0scratch/.git/file\0scratch/.git/\0";

	check_response(delta, sizeof(delta) - 1, FSMONITOR_QUERY_DELTA,
		       "builtin:2", delta + sizeof("builtin:2"),
		       sizeof(delta) - 1 - sizeof("builtin:2"));
	check_response(global, sizeof(global) - 1, FSMONITOR_QUERY_DELTA,
		       "builtin:3", global + sizeof("builtin:3"),
		       sizeof(global) - 1 - sizeof("builtin:3"));
	check_response(trivial, sizeof(trivial) - 1, FSMONITOR_QUERY_TRIVIAL,
		       "builtin:4", NULL, 0);
	check_response(nested_git, sizeof(nested_git) - 1,
		       FSMONITOR_QUERY_DELTA, "builtin:12",
		       nested_git + sizeof("builtin:12"),
		       sizeof(nested_git) - 1 - sizeof("builtin:12"));

	check_worktree_event(stale_root, strlen("/repo"), 0, 1,
			     global_path, sizeof(global_path) - 1);
	check_worktree_event("/repo/", strlen("/repo"), 0, 1,
			     global_path, sizeof(global_path) - 1);
	check_worktree_event("/repo", strlen("/repo"), 1, 1,
			     global_path, sizeof(global_path) - 1);
	check_worktree_event("/repo/tracked", strlen("/repo"), 1, 0,
			     file_path, sizeof(file_path) - 1);
	check_worktree_event("/repo/nested", strlen("/repo"), 0, 1,
			     directory_path, sizeof(directory_path) - 1);
	check_worktree_event("/repo/merged", strlen("/repo"), 1, 1,
			     both_paths, sizeof(both_paths) - 1);
	check_worktree_event("/REPO/Tracked", strlen("/repo"), 1, 0,
			     case_path, sizeof(case_path) - 1);
	check_worktree_event("/repo", strlen("/repo"), 0, 0, NULL, 0);
}

void test_fsmonitor_response__validates_hardlink_inode_markers(void)
{
	static const char inode[] =
		"builtin:5\0//inode:f123456789abcdef\0tracked\0";
	static const char zero_low_bits[] =
		"builtin:6\0//inode:0000000100000000\0";
	static const char zero[] =
		"builtin:7\0//inode:0000000000000000\0";
	static const char short_inode[] =
		"builtin:8\0//inode:123456789abcdef\0";
	static const char long_inode[] =
		"builtin:9\0//inode:0123456789abcdef0\0";
	static const char invalid_hex[] =
		"builtin:10\0//inode:0123456789abcdeg\0";
	static const char embedded_path[] =
		"builtin:11\0//inode:0123456789abcde/\0";

	check_response(inode, sizeof(inode) - 1, FSMONITOR_QUERY_DELTA,
		       "builtin:5", inode + sizeof("builtin:5"),
		       sizeof(inode) - 1 - sizeof("builtin:5"));
	check_response(zero_low_bits, sizeof(zero_low_bits) - 1,
		       FSMONITOR_QUERY_DELTA, "builtin:6",
		       zero_low_bits + sizeof("builtin:6"),
		       sizeof(zero_low_bits) - 1 - sizeof("builtin:6"));
	check_malformed(zero, sizeof(zero) - 1);
	check_malformed(short_inode, sizeof(short_inode) - 1);
	check_malformed(long_inode, sizeof(long_inode) - 1);
	check_malformed(invalid_hex, sizeof(invalid_hex) - 1);
	check_malformed(embedded_path, sizeof(embedded_path) - 1);
}
