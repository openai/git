test_lazy_prereq SEMANTIC_VERIFY_ANCHORED_OPEN '
	test_create_repo semantic-anchored-open-probe &&
	test_commit -C semantic-anchored-open-probe base tracked &&
	(
		cd semantic-anchored-open-probe &&
		test-tool semantic-verify --show-results >actual &&
		test_grep "^tracked raw-clean " actual
	)
'
