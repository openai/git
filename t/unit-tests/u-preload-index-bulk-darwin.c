#include "unit-test.h"

#ifdef __APPLE__

#include <sys/attr.h>
#include <sys/vnode.h>

#include "compat/preload-index/bulk-darwin.h"

#define REQUIRED_COMMON \
	(ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | \
	 ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | \
	 ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | \
	 ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK | \
	 ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
#define REQUIRED_FILE (ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH)

struct test_record {
	uint32_t record_len;
	attribute_set_t returned;
	uint32_t error;
	attrreference_t name_ref;
	dev_t dev;
	fsobj_type_t type;
	struct timespec birthtime;
	struct timespec mtime;
	struct timespec ctime;
	uid_t uid;
	gid_t gid;
	uint32_t access;
	uint32_t flags;
	uint64_t fileid;
	uint32_t linkcount;
	off_t size;
	char name[8];
} __attribute__((packed));

static struct test_record make_record(void)
{
	struct test_record record = {
		.record_len = sizeof(record),
		.returned = {
			.commonattr = REQUIRED_COMMON,
			.fileattr = REQUIRED_FILE,
		},
		.name_ref = {
			.attr_dataoffset = offsetof(struct test_record, name) -
				offsetof(struct test_record, name_ref),
			.attr_length = 5,
		},
		.dev = 1,
		.type = VREG,
		.uid = 1,
		.gid = 1,
		.access = 0644,
		.fileid = 1,
		.linkcount = 1,
		.size = 1,
		.name = "file",
	};

	return record;
}

static void check_malformed(struct test_record *record, size_t len)
{
	cl_assert(preload_bulk_darwin_decode_record((char *)record, len) < 0);
}

#endif /* __APPLE__ */

void test_preload_index_bulk_darwin__accepts_valid_record(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record = make_record();

	cl_assert_equal_i(0, preload_bulk_darwin_decode_record((char *)&record,
							       sizeof(record)));
#endif
}

void test_preload_index_bulk_darwin__accepts_valid_directory_record(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record = make_record();

	record.returned.fileattr = 0;
	record.returned.dirattr = ATTR_DIR_MOUNTSTATUS;
	record.type = VDIR;
	cl_assert_equal_i(0, preload_bulk_darwin_decode_record((char *)&record,
							       sizeof(record)));
#endif
}

void test_preload_index_bulk_darwin__rejects_entry_error(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record = make_record();

	record.error = EIO;
	check_malformed(&record, sizeof(record));
#endif
}

void test_preload_index_bulk_darwin__rejects_short_record(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record = make_record();

	check_malformed(&record,
			sizeof(uint32_t) + sizeof(attribute_set_t) - 1);

	record.record_len = sizeof(record) + sizeof(uint64_t);
	check_malformed(&record, sizeof(record));

	record.record_len = sizeof(uint64_t);
	check_malformed(&record, sizeof(record));

	record.record_len = sizeof(record) - 1;
	check_malformed(&record, sizeof(record));

	record.record_len = (offsetof(struct test_record, type) +
			     sizeof(uint64_t) - 1) &
			    ~(sizeof(uint64_t) - 1);
	check_malformed(&record, sizeof(record));
#endif
}

void test_preload_index_bulk_darwin__rejects_wrong_returned_attributes(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record;

	record = make_record();
	record.returned.commonattr &= ~ATTR_CMN_NAME;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.returned.volattr = 1;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.returned.fileattr &= ~ATTR_FILE_DATALENGTH;
	check_malformed(&record, sizeof(record));
#endif
}

void test_preload_index_bulk_darwin__rejects_invalid_name_reference(void)
{
#ifndef __APPLE__
	cl_skip();
#else
	struct test_record record;

	record = make_record();
	record.name_ref.attr_dataoffset = -4;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name_ref.attr_dataoffset = 2;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name_ref.attr_dataoffset = INT32_MAX;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name_ref.attr_length = UINT32_MAX;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name_ref.attr_dataoffset = 0;
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name[1] = '\0';
	check_malformed(&record, sizeof(record));

	record = make_record();
	record.name[1] = '/';
	check_malformed(&record, sizeof(record));
#endif
}
