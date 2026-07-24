#include "unit-test.h"
#include "clean-status-identity.h"

void test_clean_status_identity__requires_a_single_link_regular_file(void)
{
	struct clean_status_identity identity;
	struct stat st = { 0 };

	st.st_mode = S_IFDIR | 0755;
	st.st_nlink = 1;
	cl_assert_equal_i(clean_status_identity_from_stat(&identity, &st), -1);
	st.st_mode = S_IFREG | 0644;
	st.st_nlink = 2;
	cl_assert_equal_i(clean_status_identity_from_stat(&identity, &st), -1);
	st.st_nlink = 1;
	cl_assert_equal_i(clean_status_identity_from_stat(&identity, &st), 0);
}

void test_clean_status_identity__durability_is_platform_specific(void)
{
#ifdef __APPLE__
	cl_assert(clean_status_identity_is_durable());
#else
	cl_assert(!clean_status_identity_is_durable());
#endif
}
