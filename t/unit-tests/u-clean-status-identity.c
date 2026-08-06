#include "unit-test.h"
#include "clean-status-identity.h"
#include "strbuf.h"

void test_clean_status_identity__round_trips_fixed_width_encoding(void)
{
	struct clean_status_identity expected = {
		.stat.fields = {
			1, 2, 3, 4, 5, 6, 7,
			8, 9, 10, 11, 12, 13, 14,
		},
	};
	struct clean_status_identity actual;
	struct strbuf encoded = STRBUF_INIT;
	const unsigned char *p;

	clean_status_identity_write(&encoded, &expected);
	cl_assert_equal_i(encoded.len, CLEAN_STATUS_IDENTITY_SIZE);
	p = (const unsigned char *)encoded.buf;
	cl_assert_equal_i(clean_status_identity_read(
		&p, (const unsigned char *)encoded.buf + encoded.len, &actual), 0);
	cl_assert_equal_i(p - (const unsigned char *)encoded.buf, encoded.len);
	cl_assert(clean_status_identity_equal(&expected, &actual));
	strbuf_release(&encoded);
}

void test_clean_status_identity__rejects_every_truncation(void)
{
	struct clean_status_identity identity = { 0 }, parsed;
	struct strbuf encoded = STRBUF_INIT;

	clean_status_identity_write(&encoded, &identity);
	for (size_t len = 0; len < encoded.len; len++) {
		const unsigned char *p = (const unsigned char *)encoded.buf;

		cl_assert_equal_i(clean_status_identity_read(
			&p, (const unsigned char *)encoded.buf + len, &parsed), -1);
	}
	strbuf_release(&encoded);
}

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
