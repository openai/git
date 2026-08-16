#define USE_THE_REPOSITORY_VARIABLE
#define GIT_TEST_PROGRESS_ONLY

#include "unit-test.h"
#include "clean-status.h"
#include "progress.h"
#include "repository.h"

static int previous_progress_testing;

void test_clean_status_progress__initialize(void)
{
	previous_progress_testing = progress_testing;
	progress_testing = 1;
	clean_status_enable_progress(NULL);
}

void test_clean_status_progress__cleanup(void)
{
	clean_status_enable_progress(NULL);
	progress_testing = previous_progress_testing;
}

void test_clean_status_progress__requires_enabled_repository(void)
{
	struct repository other = { 0 };

	cl_assert_equal_p(clean_status_start_progress(
		the_repository, "disabled progress", 1), NULL);
	clean_status_enable_progress(the_repository);
	cl_assert_equal_p(clean_status_start_progress(
		&other, "other repository", 1), NULL);
}

void test_clean_status_progress__starts_updates_and_stops(void)
{
	struct clean_status_progress *progress;

	clean_status_enable_progress(the_repository);
	progress = clean_status_start_progress(
		the_repository, "clean status", 2);
	cl_assert(progress != NULL);
	clean_status_update_progress(progress, 0);
	clean_status_update_progress(progress, 1);
	clean_status_update_progress(progress, 1);
	clean_status_stop_progress(&progress);
	cl_assert_equal_p(progress, NULL);
	clean_status_update_progress(NULL, 1);
	clean_status_stop_progress(&progress);
	clean_status_stop_progress(NULL);
}
