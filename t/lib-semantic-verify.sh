test_lazy_prereq SEMANTIC_VERIFY_ANCHORED_OPEN '
	test_create_repo semantic-anchored-open-probe &&
	test_commit -C semantic-anchored-open-probe base tracked &&
	(
		cd semantic-anchored-open-probe &&
		test-tool semantic-verify --show-results >actual &&
		test_grep "^tracked raw-clean " actual
	)
'

test_lazy_prereq CLEAN_STATUS_SIDECAR '
	test_have_prereq MACOS &&
	/bin/df -l -t apfs "$TRASH_DIRECTORY" >/dev/null
'

test_remove_clean_status_sidecar () {
	if test_have_prereq CLEAN_STATUS_SIDECAR
	then
		test_path_is_file "$1" &&
		rm "$1"
	else
		test_path_is_missing "$1"
	fi
}
