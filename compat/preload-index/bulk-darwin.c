#include "git-compat-util.h"

#include <sys/attr.h>
#include <sys/vnode.h>

#include "compat/preload-index/bulk-darwin.h"

static const attrgroup_t required_common =
	ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
	ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE |
	ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
	ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK |
	ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
static const attrgroup_t required_dir = ATTR_DIR_MOUNTSTATUS;
static const attrgroup_t required_file =
	ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH;

static int valid_component(const char *component, size_t len)
{
	return len &&
		!(len == 1 && component[0] == '.') &&
		!(len == 2 && component[0] == '.' && component[1] == '.');
}

struct preload_bulk_darwin_entry {
	const char *name;
	uint32_t record_len;
	dev_t dev;
	fsobj_type_t type;
	struct timespec birthtime;
	struct timespec mtime;
	struct timespec ctime;
	uid_t uid;
	gid_t gid;
	uint32_t access;
	uint32_t flags;
	uint32_t linkcount;
	uint32_t mountstatus;
	uint64_t fileid;
	off_t size;
};

static int decode_entry(const char *record, size_t remaining,
			struct preload_bulk_darwin_entry *entry)
{
	uint32_t entry_error = 0;
	attribute_set_t returned;
	attrreference_t name_ref;
	const char *p, *end, *name_ref_at;
	size_t name_ref_offset, name_offset, name_remaining;

	if (remaining < sizeof(entry->record_len) + sizeof(returned))
		return -1;
	memcpy(&entry->record_len, record, sizeof(entry->record_len));
	if ((entry->record_len % sizeof(uint64_t)) ||
	    entry->record_len < sizeof(entry->record_len) + sizeof(returned) ||
	    entry->record_len > remaining)
		return -1;

	p = record + sizeof(entry->record_len);
	end = record + entry->record_len;
	memcpy(&returned, p, sizeof(returned));
	p += sizeof(returned);
	if (returned.commonattr != required_common ||
	    returned.volattr || returned.forkattr)
		return -1;

#define TAKE_ATTR(value) do { \
	if ((size_t)(end - p) < sizeof(value)) \
		return -1; \
	memcpy(&(value), p, sizeof(value)); \
	p += sizeof(value); \
} while (0)
	TAKE_ATTR(entry_error);
	if (entry_error)
		return -1;
	name_ref_at = p;
	TAKE_ATTR(name_ref);
	TAKE_ATTR(entry->dev);
	TAKE_ATTR(entry->type);
	TAKE_ATTR(entry->birthtime);
	TAKE_ATTR(entry->mtime);
	TAKE_ATTR(entry->ctime);
	TAKE_ATTR(entry->uid);
	TAKE_ATTR(entry->gid);
	TAKE_ATTR(entry->access);
	TAKE_ATTR(entry->flags);
	TAKE_ATTR(entry->fileid);

	if (entry->type == VDIR) {
		if (returned.dirattr != required_dir ||
		    returned.fileattr)
			return -1;
		TAKE_ATTR(entry->mountstatus);
	} else {
		if (returned.dirattr ||
		    (returned.fileattr & ~required_file))
			return -1;
		TAKE_ATTR(entry->linkcount);
		TAKE_ATTR(entry->size);
		if ((entry->type == VREG || entry->type == VLNK) &&
		    returned.fileattr != required_file)
			return -1;
	}
#undef TAKE_ATTR

	if (name_ref.attr_dataoffset < 0 ||
	    (name_ref.attr_dataoffset % (int32_t)sizeof(uint32_t)))
		return -1;
	name_ref_offset = name_ref_at - record;
	if ((uint32_t)name_ref.attr_dataoffset >
	    entry->record_len - name_ref_offset)
		return -1;
	name_offset = name_ref_offset + name_ref.attr_dataoffset;
	name_remaining = entry->record_len - name_offset;
	entry->name = record + name_offset;
	if (!name_ref.attr_length ||
	    name_ref.attr_length > name_remaining ||
	    entry->name < p)
		return -1;
	if (entry->name[name_ref.attr_length - 1] ||
	    memchr(entry->name, '\0', name_ref.attr_length - 1) ||
	    !valid_component(entry->name, name_ref.attr_length - 1) ||
	    memchr(entry->name, '/', name_ref.attr_length - 1))
		return -1;
	return 0;
}

int preload_bulk_darwin_decode_record(const char *record, size_t len)
{
	struct preload_bulk_darwin_entry entry;

	return decode_entry(record, len, &entry);
}
