#!/bin/sh

test_description='gentle entries-only reads of optional index witnesses'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_INDEX_VERSION \
	GIT_TEST_INDEX_THREADS GIT_TEST_FSMONITOR

test_expect_success PERL_TEST_HELPERS 'write index fixture generator' '
	cat >make-index.pl <<-\EOF
	use strict;
	use warnings;
	use Digest::SHA qw(sha1 sha256);
	binmode STDIN;
	binmode STDOUT;
	my ($algo, $case) = @ARGV;
	my $rawsz = $algo eq "sha256" ? 32 : 20;
	my $fixed = 40 + $rawsz + 2;
	sub digest { return $rawsz == 32 ? sha256($_[0]) : sha1($_[0]); }
	sub varint {
		my ($n) = @_;
		my @bytes = ($n & 127);
		while ($n >>= 7) { unshift @bytes, 128 | (--$n & 127); }
		return pack("C*", @bytes);
	}
	sub entry {
		my %o = @_;
		my $name = $o{name} // "alpha";
		my $version = $o{version} // 2;
		my $len = length($name);
		my $flags = ($o{flags} // 0) |
			($o{namelen} // ($len < 0xfff ? $len : 0xfff));
		my $data = pack("N10", 11, 12, 13, 14, 15, 16,
			$o{mode} // 0100644, 17, 18, 19) .
			("\x11" x $rawsz) . pack("n", $flags);
		$data .= pack("n", $o{extended} // 0) if $flags & 0x4000;
		if ($version == 4) {
			$data .= varint($o{strip} // 0) .
				($o{suffix} // $name) . "\0";
		} else {
			$data .= $name . "\0";
			$data .= "\0" x ((8 - length($data) % 8) % 8);
		}
		return $data;
	}
	if ($case eq "strip-proofs" || $case eq "unbind-proof") {
		local $/;
		my $data = <STDIN>;
		my ($version, $nr) = unpack("NN", substr($data, 4, 8));
		die "expected an uncompressed index\n" if $version < 2 || $version > 3;
		my $offset = 12;
		for (1 .. $nr) {
			my $flags = unpack("n", substr($data, $offset + 40 + $rawsz, 2));
			my $header = $fixed + (($flags & 0x4000) ? 2 : 0);
			my $len = $flags & 0xfff;
			$len = index($data, "\0", $offset + $header) - $offset - $header
				if $len == 0xfff;
			die "invalid name\n" if $len < 0;
			$offset += ($header + $len + 8) & ~7;
		}
		my $out = substr($data, 0, $offset);
		my $end = length($data) - $rawsz;
		my $proof_seen = 0;
		while ($offset < $end) {
			die "short extension\n" if $end - $offset < 8;
			my ($name, $size) = unpack("a4N", substr($data, $offset, 8));
			die "long extension\n" if $size > $end - $offset - 8;
			my $body = substr($data, $offset + 8, $size);
			$offset += 8 + $size;
			next if $name eq "FSUC";
			next if $case eq "strip-proofs" && $name eq "FSCF";
			next if $case eq "unbind-proof" && $name eq "FSMN";
			if ($case eq "unbind-proof" && $name eq "FSCF") {
				$proof_seen++;
				my $flags = unpack("N", substr($body, 8, 4));
				substr($body, 8, 4, pack("N", $flags & ~6));
				$body = substr($body, 0, -$rawsz);
				$body .= digest($body);
			}
			$out .= pack("a4N", $name, length($body)) . $body;
		}
		die "missing FSCF extension\n" if $case eq "unbind-proof" && !$proof_seen;
		print $out, digest($out);
		exit;
	}
	my $version = 2;
	my @entries = (entry());
	my $extra = "";
	my $signature = "DIRC";
	my $count;
	if ($case eq "empty") { @entries = (); }
	elsif ($case eq "stages") {
		@entries = map { entry(flags => $_ << 12) } 1 .. 3;
	}
	elsif ($case eq "extended") {
		$version = 3;
		@entries = (entry(version => 3, flags => 0xc000, extended => 0x6000));
	}
	elsif ($case eq "compressed") {
		$version = 4;
		@entries = (entry(version => 4),
			entry(version => 4, name => "alphabet", suffix => "bet"),
			entry(version => 4, name => "beta", strip => 8));
	}
	elsif ($case eq "long-compressed") {
		$version = 4;
		my $prefix = "long/" . ("a/" x 2100);
		@entries = (entry(version => 4, name => $prefix . "one"),
			entry(version => 4, name => $prefix . "two", strip => 3,
				suffix => "two"));
	}
	elsif ($case eq "optional-extensions") {
		$extra .= pack("a4N", $_, 4) . "junk"
			for qw(TREE UNTR FSMN FSCF FSUC IEOT EOIE ZZZZ);
	}
	elsif ($case eq "bad-signature") { $signature = "NOPE"; }
	elsif ($case eq "bad-version") { $version = 5; }
	elsif ($case eq "bad-count") { $count = 0xffffffff; }
	elsif ($case eq "truncated-header") {
		my $data = "DIRC";
		print $data, digest($data);
		exit;
	}
	elsif ($case eq "truncated-fixed") { $entries[0] = substr($entries[0], 0, $fixed - 1); }
	elsif ($case eq "truncated-flags") {
		$version = 3;
		@entries = (substr(entry(version => 3, flags => 0x4000,
			extended => 0x4000), 0, $fixed + 1));
	}
	elsif ($case eq "unknown-flags") {
		$version = 3;
		@entries = (entry(version => 3, flags => 0x4000, extended => 1));
	}
	elsif ($case eq "v2-extended") {
		@entries = (entry(flags => 0x4000, extended => 0x4000));
	}
	elsif ($case eq "missing-nul") {
		$version = 4;
		@entries = (substr(entry(version => 4), 0, -1));
	}
	elsif ($case eq "embedded-nul") { @entries = (entry(name => "al\0ha")); }
	elsif ($case eq "bad-padding") {
		@entries = (entry(name => "ab"));
		substr($entries[0], -1, 1, "\1");
	}
	elsif ($case eq "truncated-varint" || $case eq "overflow-varint") {
		$version = 4;
		@entries = (substr(entry(version => 4), 0, $fixed) .
			($case eq "truncated-varint" ? "\x80\x80" : ("\x80" x 10) . "\0"));
	}
	elsif ($case eq "first-strip") {
		$version = 4;
		@entries = (entry(version => 4, strip => 1));
	}
	elsif ($case eq "excessive-strip") {
		$version = 4;
		@entries = (entry(version => 4),
			entry(version => 4, name => "beta", strip => 6));
	}
	elsif ($case eq "short-name") {
		$version = 4;
		@entries = (entry(version => 4),
			entry(version => 4, name => "b", suffix => "b"));
	}
	elsif ($case eq "short-long-name") {
		$version = 4;
		@entries = (entry(version => 4, namelen => 0xfff));
	}
	elsif ($case eq "unordered") { @entries = (entry(name => "beta"), entry()); }
	elsif ($case eq "duplicate-stage") { @entries = (entry(flags => 0x1000)) x 2; }
	elsif ($case eq "mixed-stages") { @entries = (entry(), entry(flags => 0x1000)); }
	elsif ($case eq "bad-mode") { @entries = (entry(mode => 0100664)); }
	elsif ($case eq "empty-name") { @entries = (entry(name => "")); }
	elsif ($case eq "absolute-name") { @entries = (entry(name => "/alpha")); }
	elsif ($case eq "dotdot-name") { @entries = (entry(name => "a/../b")); }
	elsif ($case eq "dotgit-name") { @entries = (entry(name => "a/.GiT/b")); }
	elsif ($case eq "sparse-entry") { @entries = (entry(name => "dir/", mode => 0040000)); }
	elsif ($case eq "resolve-undo" || $case eq "split-index" ||
	       $case eq "sparse-index" || $case eq "mandatory-extension") {
		my %names = ("resolve-undo" => "REUC", "split-index" => "link",
			"sparse-index" => "sdir", "mandatory-extension" => "zzzz");
		$extra = pack("a4N", $names{$case}, 0);
	}
	elsif ($case eq "truncated-extension") { $extra = "FSMN"; }
	elsif ($case eq "oversized-extension") { $extra = pack("a4N", "FSMN", 10) . "x"; }
	elsif ($case ne "valid" && $case ne "skiphash" &&
	       $case ne "bad-checksum" && $case ne "truncated-trailer") {
		die "unknown fixture $case\n";
	}
	my $data = $signature . pack("NN", $version, $count // scalar(@entries)) .
		join("", @entries) . $extra;
	my $checksum = $case eq "skiphash" ? "\0" x $rawsz : digest($data);
	substr($checksum, 0, 1, chr(ord(substr($checksum, 0, 1)) ^ 1))
		if $case eq "bad-checksum";
	$checksum = substr($checksum, 0, -1) if $case eq "truncated-trailer";
	print $data, $checksum;
	EOF
'

for algo in sha1 sha256
do
	test_expect_success "$algo writer-produced v2/v3/v4 and skipHash witnesses" '
		git init --object-format="$algo" "$algo" &&
		git -C "$algo" config core.fsmonitor false &&
		git -C "$algo" config core.untrackedCache false &&
		git -C "$algo" config index.threads 1 &&
		mkdir "$algo/dir" &&
		test_write_lines alpha >"$algo/dir/alpha" &&
		test_write_lines alphabet >"$algo/dir/alphabet" &&
		test_write_lines beta >"$algo/dir/beta" &&
		git -C "$algo" add dir &&
		for version in 2 3 4
		do
			if test "$version" = 2
			then
				git -C "$algo" update-index --no-skip-worktree dir/alpha
			else
				git -C "$algo" update-index --skip-worktree dir/alpha
			fi &&
			for skip in false true
			do
				git -C "$algo" -c index.skipHash="$skip" update-index \
					--index-version="$version" --force-write-index &&
				test "$version" = "$(git -C "$algo" update-index --show-index-version)" &&
				cp "$algo/.git/index" "$algo/.git/witness" &&
				test-tool -C "$algo" read-cache \
					--compare-index-witness .git/witness || return 1
			done || return 1
		done
	'

	test_expect_success PTHREADS "$algo v4 IEOT block restarts use the shared decoder" '
		git -C "$algo" config index.threads 3 &&
		git -C "$algo" -c index.skipHash=false update-index \
			--index-version=4 --force-write-index &&
		cp "$algo/.git/index" "$algo/.git/witness" &&
		test_grep IEOT "$algo/.git/witness" &&
		test_grep EOIE "$algo/.git/witness" &&
		test-tool -C "$algo" read-cache --compare-index-witness .git/witness &&
		git -C "$algo" config index.threads 1
	'

	test_expect_success PERL_TEST_HELPERS "$algo exact entry fields and long compressed names" '
		for kind in valid empty stages extended compressed long-compressed skiphash
		do
			perl make-index.pl "$algo" "$kind" >"$algo/.git/witness" &&
			test-tool -C "$algo" read-cache \
				--compare-index-witness .git/witness || return 1
		done
	'

	test_expect_success PERL_TEST_HELPERS "$algo optional extensions are not decoded or installed" '
		perl make-index.pl "$algo" optional-extensions >"$algo/.git/witness" &&
		test-tool -C "$algo" read-cache --read-index-witness .git/witness
	'

	test_expect_success PERL_TEST_HELPERS "$algo malformed and unsupported witnesses are clean misses" '
		for kind in bad-signature bad-version bad-count bad-checksum \
			truncated-header truncated-fixed truncated-flags unknown-flags \
			v2-extended missing-nul embedded-nul bad-padding \
			truncated-varint overflow-varint first-strip excessive-strip \
			short-name short-long-name unordered duplicate-stage mixed-stages \
			bad-mode empty-name absolute-name dotdot-name dotgit-name \
			sparse-entry resolve-undo split-index sparse-index \
			mandatory-extension truncated-extension oversized-extension \
			truncated-trailer
		do
			perl make-index.pl "$algo" "$kind" >"$algo/.git/witness" &&
			test-tool -C "$algo" read-cache \
				--expect-index-witness-miss .git/witness || return 1
		done
	'

	test_expect_success PERL_TEST_HELPERS "$algo real-index corruption remains fatal" '
		for kind in truncated-header unknown-flags excessive-strip
		do
			perl make-index.pl "$algo" "$kind" >"$algo/.git/witness" &&
			test_must_fail env GIT_INDEX_FILE="$PWD/$algo/.git/witness" \
				git -C "$algo" ls-files >out 2>err &&
			test_grep "^fatal:" err || return 1
		done
	'

	test_expect_success PERL_TEST_HELPERS "$algo pinned reader never reopens a pruned pathname" '
		perl make-index.pl "$algo" valid >"$algo/.git/witness" &&
		test-tool -C "$algo" read-cache \
			--read-index-witness-unlink .git/witness &&
		test_path_is_missing "$algo/.git/witness" &&
		test-tool -C "$algo" read-cache \
			--expect-index-witness-miss .git/witness
	'

	test_expect_success PIPE "$algo witness and installer snapshot reject a FIFO" '
		rm -f "$algo/.git/witness" &&
		mkfifo "$algo/.git/witness" &&
		test_when_finished "rm -f $algo/.git/witness" &&
		test-tool -C "$algo" read-cache \
			--expect-index-witness-miss .git/witness &&
		test_must_fail test-tool -C "$algo" read-cache \
			--index-witness-snapshot .git/witness
	'
done

test_lazy_prereq INDEX_WITNESS_APFS '
	test_have_prereq MACOS &&
	/bin/df -t apfs "$TRASH_DIRECTORY" >/dev/null
'

# Inspect the framed extensions, not an incidental "FSCF" string in the index.
# These fixtures deliberately write v2 indexes with real checksums.  Without
# an explicit expected token, require the real Darwin provider used below.
test_index_witness_full_proof () {
	perl - "$1" "$(git rev-parse --show-object-format)" "${2-}" <<-\EOF
	use strict;
	use warnings;
	use Digest::SHA qw(sha1 sha256);
	my ($path, $algo, $expected_token) = @ARGV;
	my $rawsz = $algo eq "sha256" ? 32 : 20;
	sub digest { return $rawsz == 32 ? sha256($_[0]) : sha1($_[0]); }
	open my $input, "<", $path or die "cannot read $path: $!\n";
	binmode $input;
	local $/;
	my $index = <$input>;
	my $end = length($index) - $rawsz;
	die "bad index checksum in $path\n" if $end < 12 ||
		digest(substr($index, 0, $end)) ne substr($index, $end);
	my ($signature, $version, $nr) = unpack("a4NN", substr($index, 0, 12));
	die "expected an uncompressed index in $path\n"
		if $signature ne "DIRC" || $version < 2 || $version > 3;
	my $offset = 12;
	for (1 .. $nr) {
		my $fixed = 40 + $rawsz + 2;
		die "short index entry in $path\n" if $end - $offset < $fixed;
		my $flags = unpack("n", substr($index, $offset + $fixed - 2, 2));
		my $header = $fixed + (($flags & 0x4000) ? 2 : 0);
		die "short entry flags in $path\n" if $end - $offset < $header;
		my $nul = index($index, "\0", $offset + $header);
		my $len = $flags & 0xfff;
		die "bad index name in $path\n" if $nul < 0 || $nul >= $end ||
			($len != 0xfff && $nul != $offset + $header + $len);
		$len = $nul - $offset - $header;
		$offset += ($header + $len + 8) & ~7;
		die "short index padding in $path\n" if $offset > $end;
	}
	my %ext;
	while ($offset < $end) {
		die "short extension in $path\n" if $end - $offset < 8;
		my ($name, $size) = unpack("a4N", substr($index, $offset, 8));
		die "bad extension $name in $path\n"
			if $size > $end - $offset - 8 || exists $ext{$name};
		$ext{$name} = substr($index, $offset + 8, $size);
		$offset += 8 + $size;
	}
	my $proof = $ext{FSCF} // die "missing FSCF in $path\n";
	die "short FSCF in $path\n" if length($proof) < 20;
	my ($pv, $magic, $flags, $token_len, $manifest_len) =
		unpack("N5", substr($proof, 0, 20));
	die "incomplete FSCF in $path (version $pv, flags $flags)\n"
		if ($pv != 1 && $pv != 2) || $magic != 0x46534331 ||
		   $flags != 15 || !$token_len ||
		   length($proof) != 20 + $token_len + $manifest_len +
			($pv == 2 ? 5 : 4) * $rawsz ||
		   digest(substr($proof, 0, -$rawsz)) ne substr($proof, -$rawsz);
	my $token = substr($proof, 20, $token_len);
	if (length($expected_token)) {
		die "unexpected provider token in $path\n"
			if $token ne $expected_token;
	} else {
		die "not a real builtin token in $path\n"
			if $token !~ /^builtin:dirmeta-v1\.inode-v1\./;
	}
	for my $name (qw(FSMN FSUC)) {
		my $body = $ext{$name} // die "missing $name in $path\n";
		my $want_version = $name eq "FSMN" ? 2 : 1;
		my $nul = index($body, "\0", 4);
		die "unbound $name in $path\n"
			if length($body) < 5 || unpack("N", substr($body, 0, 4)) !=
				$want_version || $nul < 4 ||
			   substr($body, 4, $nul - 4) ne $token;
	}
	die "missing UNTR in $path\n" if !exists $ext{UNTR};
	print "FSCF version $pv flags $flags token $token\n";
	EOF
}

test_index_witness_cookie_health () (
	witness_cookie_label=$1 &&
	GIT_TRACE2_EVENT="$PWD/.git/$witness_cookie_label.cookie-initial.trace" \
		test-tool fsmonitor-client query --token 0 \
			>".git/$witness_cookie_label.cookie-initial" &&
	nul_to_q <".git/$witness_cookie_label.cookie-initial" \
		>".git/$witness_cookie_label.cookie-initial.q" &&
	test_grep "^builtin:.*Q/Q$" \
		".git/$witness_cookie_label.cookie-initial.q" &&
	witness_cookie_token=$(sed "s/Q.*//" \
		".git/$witness_cookie_label.cookie-initial.q") &&
	# A failed startup cookie may already have retired an older epoch.
	wc -c <.git/witness-daemon.trace \
		>".git/$witness_cookie_label.cookie-daemon.offset" &&
	witness_cookie_log_offset=$(cat \
		".git/$witness_cookie_label.cookie-daemon.offset") &&
	GIT_TRACE2_EVENT="$PWD/.git/$witness_cookie_label.cookie-healthy.trace" \
		test-tool fsmonitor-client query --token "$witness_cookie_token" \
			>".git/$witness_cookie_label.cookie-healthy" &&
	tail -c "+$((witness_cookie_log_offset + 1))" .git/witness-daemon.trace \
		>".git/$witness_cookie_label.cookie-daemon.trace" &&
	nul_to_q <".git/$witness_cookie_label.cookie-healthy" \
		>".git/$witness_cookie_label.cookie-healthy.q" &&
	test_grep "^builtin:.*Q" \
		".git/$witness_cookie_label.cookie-healthy.q" &&
	test_grep ! "Q/Q$" ".git/$witness_cookie_label.cookie-healthy.q" &&
	test_grep "cookie-seen:" ".git/$witness_cookie_label.cookie-daemon.trace" &&
	test_grep ! "cookie_wait timed out" \
		".git/$witness_cookie_label.cookie-daemon.trace"
)

test_index_witness_physical_prime () (
	witness_prime_label=$1 &&
	test_index_witness_cookie_health "$witness_prime_label" &&
	# The physical index must carry the full source proof before CSH issuance.
	GIT_OPTIONAL_LOCKS=1 GIT_INDEX_FILE="$PWD/.git/index" \
	GIT_TRACE2_EVENT="$PWD/.git/$witness_prime_label.prime.trace" \
		git status --porcelain=v2 >".git/$witness_prime_label.prime" &&
	test_index_witness_full_proof .git/index \
		>".git/$witness_prime_label.proof"
)

test_index_witness_native_baseline () {
	sane_unset GIT_INDEX_FILE GIT_INDEX_VERSION \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TEST_FSMONITOR_QUERY_PATH \
		GIT_TEST_FSMONITOR_QUERY_BARRIER_AT \
		GIT_TEST_FSMONITOR_QUERY_BARRIER_READY \
		GIT_TEST_FSMONITOR_QUERY_BARRIER_RESUME GIT_TEST_FSMONITOR_TOKEN &&
	git config index.version 2 &&
	git config index.skipHash false &&
	git config core.autocrlf false &&
	git config core.trustctime true &&
	git config core.checkStat default &&
	git config core.untrackedCache true &&
	git config core.fsmonitor false &&
	test-tool chmtime -120 "$@" &&
	git update-index --refresh &&
	git update-index --index-version=2 --force-write-index &&
	git config core.fsmonitor true &&
	GIT_TRACE_FSMONITOR="$PWD/.git/witness-daemon.trace" \
	GIT_TRACE2_EVENT="$PWD/.git/witness-daemon.trace2" \
		git fsmonitor--daemon start --start-timeout=10 &&
	GIT_TRACE2_EVENT="$PWD/.git/baseline.enable.trace" \
		git update-index --fsmonitor &&
	test_index_witness_physical_prime baseline &&
	test_must_be_empty .git/baseline.prime
}

test_index_witness_issue_history () {
	witness_issue_label=$1 &&
	witness_issue_expected_token=${2-} &&
	GIT_OPTIONAL_LOCKS=1 \
	GIT_TRACE2_EVENT="$PWD/.git/$witness_issue_label.issue.trace" \
		git status --short >".git/$witness_issue_label.issue" &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<".git/$witness_issue_label.issue.trace" &&
	find .git -maxdepth 1 -type f -name "index.csh1.*" >.git/checkpoints &&
	find .git -maxdepth 1 -type f -name "index.cswi.*" >.git/witnesses &&
	test_line_count = 1 .git/checkpoints &&
	test_line_count = 1 .git/witnesses &&
	checkpoint=$(cat .git/checkpoints) &&
	witness=$(cat .git/witnesses) &&
	test_index_witness_full_proof "$witness" "$witness_issue_expected_token" \
		>".git/$witness_issue_label.witness-proof" &&
	cp "$checkpoint" .git/checkpoint.good &&
	cp "$witness" .git/witness.good
}

test_lazy_prereq INDEX_WITNESS_HEALTHY_NATIVE_COOKIE '
	test_have_prereq INDEX_WITNESS_APFS,FSMONITOR_DAEMON &&
	test_create_repo index-witness-native-cookie-prerequisite &&
	(
		cd index-witness-native-cookie-prerequisite &&
		trap "git fsmonitor--daemon stop >/dev/null 2>&1 || :" 0 &&
		git config core.fsmonitor true &&
		GIT_TRACE_FSMONITOR="$PWD/.git/witness-daemon.trace" \
			git fsmonitor--daemon start --start-timeout=10 &&
		test_index_witness_cookie_health native-prerequisite &&
		test_grep ! "cookie_wait timed out" .git/witness-daemon.trace
	)
'

test_expect_success INDEX_WITNESS_APFS,FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS,INDEX_WITNESS_HEALTHY_NATIVE_COOKIE \
	'corrupt external semantic witnesses fall back with a valid main index' '
	test_when_finished "git -C recovery fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo recovery &&
	(
		cd recovery &&
		test_commit base tracked &&
		test_index_witness_native_baseline tracked &&
		test_index_witness_issue_history recovery &&
		test_must_be_empty .git/recovery.issue &&
		test_write_lines changed >tracked &&
		git update-index --add tracked &&
		perl ../make-index.pl "$(git rev-parse --show-object-format)" \
			strip-proofs <.git/index >.git/index.foreign &&
		cp .git/index.foreign .git/index &&
		cp .git/checkpoint.good "$checkpoint" &&
		cp .git/witness.good "$witness" &&
		git -c core.fsmonitor=false --no-optional-locks \
			status --porcelain=v2 >.git/expect &&
		GIT_TRACE2_EVENT="$PWD/.git/valid.trace" \
			git --no-optional-locks status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data fsmonitor history/external-semantic-restored 1 \
			<.git/valid.trace &&
		for kind in truncated-header unknown-flags excessive-strip
		do
			cp .git/index.foreign .git/index &&
			cp .git/checkpoint.good "$checkpoint" &&
			perl ../make-index.pl "$(git rev-parse --show-object-format)" \
				"$kind" >"$witness" &&
			GIT_TRACE2_EVENT="$PWD/.git/$kind.trace" \
				git --no-optional-locks status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_cmp_bin .git/index.foreign .git/index &&
			! test_trace2_data fsmonitor history/external-semantic-restored 1 \
				<".git/$kind.trace" || return 1
		done &&
		if test_have_prereq PIPE
		then
			cp .git/index.foreign .git/index &&
			cp .git/checkpoint.good "$checkpoint" &&
			rm -f "$witness" &&
			mkfifo "$witness" &&
			GIT_TRACE2_EVENT="$PWD/.git/fifo.trace" \
				git --no-optional-locks status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_cmp_bin .git/index.foreign .git/index &&
			! test_trace2_data fsmonitor history/external-semantic-restored 1 \
				<.git/fifo.trace &&
			rm -f "$witness"
		fi
	)
'

test_expect_success INDEX_WITNESS_APFS,FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS,INDEX_WITNESS_HEALTHY_NATIVE_COOKIE \
	'bootstrap manifest recovery treats a damaged witness as a miss' '
	test_when_finished "git -C bootstrap fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo bootstrap &&
	(
		cd bootstrap &&
		test_commit base tracked &&
		test_write_lines "tracked diff=old" >.gitattributes &&
		git add .gitattributes &&
		git commit -qm attributes &&
		test_index_witness_native_baseline tracked .gitattributes &&
		git -c core.fsmonitor=false --no-optional-locks \
			rev-parse :.gitattributes >.git/attributes.old-oid &&
		test_write_lines "tracked diff=new" >.gitattributes &&
		test-tool chmtime -120 .gitattributes &&
		test_index_witness_physical_prime bootstrap &&
		test_grep "^1 \\.M .* .gitattributes$" .git/bootstrap.prime &&
		git -c core.fsmonitor=false --no-optional-locks \
			rev-parse :.gitattributes >.git/attributes.still-staged &&
		test_cmp .git/attributes.old-oid .git/attributes.still-staged &&
		test_index_witness_issue_history bootstrap &&
		test_write_lines " M .gitattributes" >.git/bootstrap.expect &&
		test_cmp .git/bootstrap.expect .git/bootstrap.issue &&
		GIT_INDEX_FILE="$PWD/.git/witness.good" \
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse :.gitattributes >.git/attributes.witness-oid &&
		test_cmp .git/attributes.old-oid .git/attributes.witness-oid &&
		git -c core.fsmonitor=false update-index --add .gitattributes &&
		perl ../make-index.pl "$(git rev-parse --show-object-format)" \
			unbind-proof <.git/index >.git/index.foreign &&
		cp .git/index.foreign .git/index &&
		cp .git/checkpoint.good "$checkpoint" &&
		cp .git/witness.good "$witness" &&
		git -c core.fsmonitor=false --no-optional-locks \
			status --porcelain=v2 >.git/expect &&
		GIT_TRACE2_EVENT="$PWD/.git/valid.trace" \
			git --no-optional-locks status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data fsmonitor history/external-bootstrap-manifest 1 \
			<.git/valid.trace &&
		cp .git/index.foreign .git/index &&
		cp .git/checkpoint.good "$checkpoint" &&
		perl ../make-index.pl "$(git rev-parse --show-object-format)" \
			truncated-header >"$witness" &&
		GIT_TRACE2_EVENT="$PWD/.git/corrupt.trace" \
			git --no-optional-locks status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_cmp_bin .git/index.foreign .git/index &&
		! test_trace2_data fsmonitor history/external-bootstrap-manifest 1 \
			<.git/corrupt.trace
	)
'

test_lazy_prereq INDEX_WITNESS_SCRIPTED_IPC '
	test-tool simple-ipc SUPPORTS_SIMPLE_IPC
'

# This provider exists in the pre-fix runtime too.  Its one stable token is
# truthful only while the worktree is unchanged: make every worktree edit
# before starting it, and keep all later fixture writes inside .git.
index_witness_scripted_token=builtin:test-capable:0

test_index_witness_scripted_prepare () {
	sane_unset GIT_INDEX_FILE GIT_INDEX_VERSION \
		GIT_TEST_FSMONITOR GIT_TEST_FSMONITOR_QUERY_SEQUENCE \
		GIT_TEST_FSMONITOR_QUERY_PATH GIT_TEST_FSMONITOR_QUERY_BARRIER_AT \
		GIT_TEST_FSMONITOR_QUERY_BARRIER_READY \
		GIT_TEST_FSMONITOR_QUERY_BARRIER_RESUME GIT_TEST_FSMONITOR_TOKEN &&
	git config index.version 2 &&
	git config index.skipHash false &&
	git config core.autocrlf false &&
	git config core.trustctime true &&
	git config core.checkStat default &&
	git config core.preloadIndex false &&
	git config core.untrackedCache true &&
	git config core.fsmonitor false &&
	test-tool chmtime -120 "$@" &&
	git update-index --refresh &&
	git update-index --index-version=2 --force-write-index &&
	git config core.fsmonitor true
}

test_index_witness_scripted_start () {
	witness_ipc_path=$(git rev-parse --path-format=absolute \
		--git-path fsmonitor--daemon.ipc) &&
	GIT_TRACE2_EVENT="$PWD/.git/scripted-provider.trace" \
		test-tool simple-ipc start-daemon --name="$witness_ipc_path" \
			--threads=1 --fsmonitor-capability-superset &&
	printf "%s\000/\000" "$index_witness_scripted_token" \
		>.git/scripted-initial.expect &&
	printf "%s\000" "$index_witness_scripted_token" \
		>.git/scripted-clean.expect &&
	GIT_TRACE2_EVENT="$PWD/.git/scripted-initial.trace" \
		test-tool fsmonitor-client query --token 0 \
			>.git/scripted-initial.actual &&
	test_cmp_bin .git/scripted-initial.expect .git/scripted-initial.actual &&
	for witness_query in first repeated
	do
		GIT_TRACE2_EVENT="$PWD/.git/scripted-$witness_query.trace" \
			test-tool fsmonitor-client query \
				--token "$index_witness_scripted_token" \
				>".git/scripted-$witness_query.actual" &&
		test_cmp_bin .git/scripted-clean.expect \
			".git/scripted-$witness_query.actual" || return 1
	done &&
	GIT_TRACE2_EVENT="$PWD/.git/scripted-enable.trace" \
		git update-index --fsmonitor
}

test_index_witness_scripted_prime () {
	witness_prime_label=$1 &&
	GIT_OPTIONAL_LOCKS=1 GIT_INDEX_FILE="$PWD/.git/index" \
	GIT_TRACE2_EVENT="$PWD/.git/$witness_prime_label.prime.trace" \
		git status --porcelain=v2 >".git/$witness_prime_label.prime" &&
	test_index_witness_full_proof .git/index \
		"$index_witness_scripted_token" \
		>".git/$witness_prime_label.proof"
}

# Check the real, issued CSHS v2 source alias.  Perl exposes the ordinary stat
# fields; Darwin stat adds the durable birth time and inode generation.  The
# nanosecond fields remain in the authenticated record and are range-checked.
test_index_witness_scripted_source () {
	perl - "$checkpoint" "$witness" \
		"$(git rev-parse --show-object-format)" \
		"$index_witness_scripted_token" <<-\EOF
	use strict;
	use warnings;
	use Digest::SHA qw(sha1 sha256);
	my ($checkpoint, $witness, $algo, $token) = @ARGV;
	my $rawsz = $algo eq "sha256" ? 32 : 20;
	sub digest { return $rawsz == 32 ? sha256($_[0]) : sha1($_[0]); }
	sub read_file {
		open my $fh, "<", $_[0] or die "cannot read $_[0]: $!\n";
		binmode $fh;
		local $/;
		return <$fh>;
	}
	my $source = read_file(".git/scripted-source.index");
	my $record = read_file($checkpoint);
	my $end = length($record) - $rawsz;
	my $offset = 12 + 2 * $rawsz;
	die "bad source checksum\n" if length($source) < 12 + $rawsz ||
		digest(substr($source, 0, -$rawsz)) ne substr($source, -$rawsz);
	die "bad CSHS checksum\n" if $end < $offset + 112 + 8 + $rawsz + 16 ||
		digest(substr($record, 0, $end)) ne substr($record, $end);
	my ($magic, $version, $flags) = unpack("a4NN", substr($record, 0, 12));
	die "missing complete CSHS v2 source alias\n"
		if $magic ne "CSHS" || $version != 2 || $flags != 15;
	my $namespace = unpack("H*", substr($record, 12, $rawsz));
	die "checkpoint and witness namespaces differ\n"
		if $checkpoint !~ /\.csh1\.\Q$namespace\E\z/ ||
		   $witness !~ /\.cswi\.\Q$namespace\E\z/;
	my @identity = unpack("Q>*", substr($record, $offset, 112));
	$offset += 112;
	my @stat = split(/\s+/, read_file(".git/scripted-source.stat"));
	my @fields = (0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13);
	die "incomplete source stat\n" if @stat != @fields;
	for my $i (0 .. $#fields) {
		die "source identity field $fields[$i] differs\n"
			if $identity[$fields[$i]] != $stat[$i];
	}
	die "source is not an owned regular single-link index\n"
		if ($identity[2] & 0170000) != 0100000 ||
		   $identity[3] != 1 || $identity[4] != $>;
	for my $i (8, 10, 12) {
		die "invalid source nanoseconds\n" if $identity[$i] >= 1000000000;
	}
	my ($source_version, $source_nr) = unpack("NN", substr($record, $offset, 8));
	$offset += 8;
	die "source header differs\n"
		if substr($source, 0, 4) ne "DIRC" ||
		   substr($source, 4, 8) ne pack("NN", $source_version, $source_nr);
	die "source trailer differs\n"
		if substr($record, $offset, $rawsz) ne substr($source, -$rawsz);
	$offset += $rawsz;
	my @lengths = unpack("N4", substr($record, $offset, 16));
	$offset += 16;
	my %ext;
	for my $name (qw(FSMN UNTR FSCF FSUC)) {
		my $len = shift @lengths;
		die "short checkpoint $name\n" if !$len || $len > $end - $offset;
		$ext{$name} = substr($record, $offset, $len);
		$offset += $len;
	}
	die "trailing checkpoint bytes\n" if $offset != $end;
	my $proof = $ext{FSCF};
	die "short checkpoint FSCF\n" if length($proof) < 20;
	my ($pv, $pmagic, $pf, $token_len, $manifest_len) =
		unpack("N5", substr($proof, 0, 20));
	die "checkpoint does not carry FULL15\n"
		if ($pv != 1 && $pv != 2) || $pmagic != 0x46534331 || $pf != 15 ||
		   $token_len != length($token) || substr($proof, 20, $token_len) ne $token ||
		   length($proof) != 20 + $token_len + $manifest_len +
			($pv == 2 ? 5 : 4) * $rawsz ||
		   digest(substr($proof, 0, -$rawsz)) ne substr($proof, -$rawsz);
	for my $name (qw(FSMN FSUC)) {
		my $body = $ext{$name};
		my $want_version = $name eq "FSMN" ? 2 : 1;
		die "checkpoint has an unbound $name\n"
			if substr($body, 0, 4) ne pack("N", $want_version) ||
			   substr($body, 4, length($token) + 1) ne "$token\0";
	}
	print "CSHS v2 source $identity[0]:$identity[1] ",
		"birth $identity[11] generation $identity[13] ",
		"index $source_version entries $source_nr checksum ",
		unpack("H*", substr($source, -$rawsz)), "\n";
	EOF
}

test_index_witness_scripted_issue_history () {
	perl -e '
		use strict;
		use warnings;
		my @st = lstat($ARGV[0]);
		die "cannot stat source index: $!\n" if !@st;
		print join(" ", @st[0, 1, 2, 3, 4, 5, 7, 9, 10]), "\n";
	' .git/index >.git/scripted-source.stat &&
	/usr/bin/stat -f "%DB %Uv" .git/index >>.git/scripted-source.stat &&
	cp .git/index .git/scripted-source.index &&
	test_index_witness_issue_history "$1" "$index_witness_scripted_token" &&
	test_cmp_bin .git/scripted-source.index .git/witness.good &&
	test_index_witness_scripted_source >.git/scripted-source.proof
}

# A FIFO regression must fail instead of hanging the whole test suite.  Keep
# the child's actual exit status, and reserve 124 for a killed timeout.
test_index_witness_watchdog () {
	perl -e '
		use strict;
		use warnings;
		use Errno qw(EINTR);
		my $seconds = shift @ARGV;
		my $pid = fork();
		die "cannot fork watchdog: $!\n" if !defined($pid);
		if (!$pid) {
			exec @ARGV or die "cannot exec $ARGV[0]: $!\n";
		}
		my $timed_out = 0;
		$SIG{ALRM} = sub { $timed_out = 1; kill "KILL", $pid; };
		alarm $seconds;
		my $waited;
		do { $waited = waitpid($pid, 0); } while $waited < 0 && $! == EINTR;
		my $status = $?;
		alarm 0;
		die "cannot reap watchdog child: $!\n" if $waited != $pid;
		if ($timed_out) {
			warn "index witness command timed out after $seconds seconds\n";
			exit 124;
		}
		exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
	' "$@"
}

test_index_witness_scripted_restore () {
	cp .git/index.foreign .git/index &&
	cp .git/checkpoint.good "$checkpoint" &&
	rm -f "$witness" &&
	cp .git/witness.good "$witness"
}

test_index_witness_scripted_status () (
	witness_status_label=$1 &&
	witness_status_key=$2 &&
	witness_status_expected=$3 &&
	if GIT_TRACE2_EVENT="$PWD/.git/$witness_status_label.trace" \
		test_index_witness_watchdog 20 git --no-optional-locks \
			status --porcelain=v2 >".git/$witness_status_label.actual" \
			2>".git/$witness_status_label.err"
	then
		echo 0 >".git/$witness_status_label.exit"
	else
		witness_status_ret=$? &&
		echo "$witness_status_ret" >".git/$witness_status_label.exit" &&
		cat ".git/$witness_status_label.err" >&2
		return 1
	fi &&
	test_cmp .git/expect ".git/$witness_status_label.actual" &&
	test_cmp_bin .git/index.foreign .git/index &&
	test_cmp_bin .git/checkpoint.good "$checkpoint" &&
	test_grep ! '"key":"query/incompatible-daemon"' \
		".git/$witness_status_label.trace" &&
	test_grep ! '"argv":.*"fsmonitor--daemon","run","--detach"' \
		".git/$witness_status_label.trace" &&
	if test "$witness_status_expected" = restored
	then
		test_trace2_data fsmonitor "$witness_status_key" 1 \
			<".git/$witness_status_label.trace"
	else
		! test_trace2_data fsmonitor "$witness_status_key" 1 \
			<".git/$witness_status_label.trace"
	fi
)

test_index_witness_scripted_recovery () (
	witness_recovery_key=$1 &&
	test_index_witness_scripted_restore &&
	test_index_witness_scripted_status valid-before \
		"$witness_recovery_key" restored || return 1
	witness_recovery_failed=0
	for witness_kind in truncated-header unknown-flags excessive-strip
	do
		if test_index_witness_scripted_restore &&
			perl ../make-index.pl "$(git rev-parse --show-object-format)" \
				"$witness_kind" >"$witness" &&
			test_index_witness_scripted_status "$witness_kind" \
				"$witness_recovery_key" miss
		then
			:
		else
			witness_recovery_failed=1
		fi
	done
	if test_index_witness_scripted_restore &&
		rm -f "$witness" &&
		mkfifo "$witness" &&
		test_index_witness_scripted_status fifo \
			"$witness_recovery_key" miss &&
		test -p "$witness"
	then
		:
	else
		witness_recovery_failed=1
	fi
	# Even a pre-fix failure must reach the FIFO and closing positive control.
	if test_index_witness_scripted_restore &&
		test_index_witness_scripted_status valid-after \
			"$witness_recovery_key" restored
	then
		:
	else
		witness_recovery_failed=1
	fi
	test "$witness_recovery_failed" = 0
)

test_expect_success INDEX_WITNESS_APFS,FSMONITOR_DAEMON,INDEX_WITNESS_SCRIPTED_IPC,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS,PIPE \
	'scripted-provider semantic recovery ignores damaged optional witnesses' '
	test_when_finished "test-tool -C scripted-recovery simple-ipc stop-daemon --name=.git/fsmonitor--daemon.ipc --max-wait=5 2>/dev/null || :" &&
	test_create_repo scripted-recovery &&
	(
		cd scripted-recovery &&
		test_commit base tracked &&
		test_write_lines stable >stable &&
		git add stable &&
		git commit -qm stable &&
		test_write_lines changed >.git/replacement &&
		git hash-object -w --stdin <.git/replacement >.git/replacement.oid &&
		test_index_witness_scripted_prepare tracked stable &&
		test_index_witness_scripted_start &&
		test_index_witness_scripted_prime semantic &&
		test_must_be_empty .git/semantic.prime &&
		test_index_witness_scripted_issue_history semantic &&
		test_must_be_empty .git/semantic.issue &&
		# Only the index changes; the provider can truthfully stay at its token.
		git update-index --cacheinfo \
			"100644,$(cat .git/replacement.oid),tracked" &&
		perl ../make-index.pl "$(git rev-parse --show-object-format)" \
			strip-proofs <.git/index >.git/index.foreign &&
		GIT_INDEX_FILE="$PWD/.git/index.foreign" \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >.git/expect &&
		test_line_count = 1 .git/expect &&
		test_grep "^1 MM .* tracked$" .git/expect &&
		test_index_witness_scripted_recovery \
			history/external-semantic-restored
	)
'

test_expect_success INDEX_WITNESS_APFS,FSMONITOR_DAEMON,INDEX_WITNESS_SCRIPTED_IPC,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS,PIPE \
	'scripted-provider bootstrap recovery ignores damaged optional witnesses' '
	test_when_finished "test-tool -C scripted-bootstrap simple-ipc stop-daemon --name=.git/fsmonitor--daemon.ipc --max-wait=5 2>/dev/null || :" &&
	test_create_repo scripted-bootstrap &&
	(
		cd scripted-bootstrap &&
		test_commit base tracked &&
		test_write_lines "tracked diff=old" >.gitattributes &&
		git add .gitattributes &&
		git commit -qm attributes &&
		test_index_witness_scripted_prepare tracked .gitattributes &&
		git -c core.fsmonitor=false --no-optional-locks \
			rev-parse :.gitattributes >.git/attributes.old-oid &&
		# This edit predates the synthetic provider; no later query may omit it.
		test_write_lines "tracked diff=new" >.gitattributes &&
		test-tool chmtime -120 .gitattributes &&
		test_index_witness_scripted_start &&
		test_index_witness_scripted_prime bootstrap &&
		test_grep "^1 \\.M .* .gitattributes$" .git/bootstrap.prime &&
		git -c core.fsmonitor=false --no-optional-locks \
			rev-parse :.gitattributes >.git/attributes.still-staged &&
		test_cmp .git/attributes.old-oid .git/attributes.still-staged &&
		test_index_witness_scripted_issue_history bootstrap &&
		test_write_lines " M .gitattributes" >.git/bootstrap.expect &&
		test_cmp .git/bootstrap.expect .git/bootstrap.issue &&
		GIT_INDEX_FILE="$PWD/.git/witness.good" \
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse :.gitattributes >.git/attributes.witness-oid &&
		test_cmp .git/attributes.old-oid .git/attributes.witness-oid &&
		git -c core.fsmonitor=false update-index --add .gitattributes &&
		perl ../make-index.pl "$(git rev-parse --show-object-format)" \
			unbind-proof <.git/index >.git/index.foreign &&
		GIT_INDEX_FILE="$PWD/.git/index.foreign" \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >.git/expect &&
		test_line_count = 1 .git/expect &&
		test_grep "^1 M\\. .* .gitattributes$" .git/expect &&
		test_index_witness_scripted_recovery \
			history/external-bootstrap-manifest
	)
'

test_done
