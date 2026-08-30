/*
 * test-mktemp.c: code to exercise the creation of temporary files
 */
#include "test-tool.h"
#include "git-compat-util.h"
#include "tempfile.h"

int cmd__mktemp(int argc, const char **argv)
{
	char *template;
	int fd;
	struct tempfile *tempfile;

	if (argc == 3 && !strcmp(argv[1], "--reopen-write-only")) {
		tempfile = mks_tempfile_m(argv[2], 0200);
		if (!tempfile)
			die_errno("unable to create tempfile");
		if (close_tempfile_gently(tempfile))
			die_errno("unable to close tempfile");
		if (reopen_tempfile_for_readwrite(tempfile) >= 0)
			die("unexpectedly reopened write-only tempfile for reading");
		if (reopen_tempfile(tempfile) < 0)
			die_errno("unable to reopen write-only tempfile");
		if (delete_tempfile(&tempfile))
			die_errno("unable to delete tempfile");
		return 0;
	}

	if (argc != 2)
		usage("Expected 1 parameter defining the temporary file template");
	template = xstrdup(argv[1]);

	fd = xmkstemp(template);

	close(fd);
	free(template);
	return 0;
}
