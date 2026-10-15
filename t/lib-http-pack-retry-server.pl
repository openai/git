#!/usr/bin/perl

use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;

my ($mode, $packfile, $cutoff, $ready_path, $result_path) = @ARGV;
defined($result_path) or
	die "usage: $0 <mode> <packfile> <cutoff> <ready> <result>\n";
$cutoff =~ /^\d+$/ && $cutoff > 0 or die "invalid cutoff: $cutoff\n";

my $completed = 0;
my $pack = "";

END {
	if (!$completed) {
		open(my $ready, ">", $ready_path);
		print $ready "failed\n" if $ready;
	}
}

$SIG{ALRM} = sub { die "timed out serving $mode request\n" };
alarm 30;

if ($packfile ne "-") {
	open(my $in, "<:raw", $packfile) or die "open $packfile: $!";
	$pack = do { local $/; <$in> };
	close($in) or die "close $packfile: $!";
	length($pack) > $cutoff or die "pack is too short";
}

my $server = IO::Socket::INET->new(
	LocalAddr => "127.0.0.1",
	LocalPort => 0,
	Proto => "tcp",
	Listen => 4,
	ReuseAddr => 1,
) or die "listen: $!";

open(my $ready, ">", $ready_path) or die "open $ready_path: $!";
print $ready $server->sockport() . "\n" or die "write $ready_path: $!";
close($ready) or die "close $ready_path: $!";

open(my $result, ">", $result_path) or die "open $result_path: $!";

sub write_all {
	my ($out, $data) = @_;
	my $offset = 0;

	while ($offset < length($data)) {
		my $written = syswrite($out, $data,
			length($data) - $offset, $offset);
		defined($written) && $written or die "write response: $!";
		$offset += $written;
	}
}

sub accept_request {
	my $request = $server->accept() or die "accept request: $!";
	my $request_line = <$request> // die "read request: $!";
	my $range = "";

	while (<$request>) {
		last if /^\r?\n$/;
		$range = $1 if /^Range:\s*(.*?)\r?$/i;
	}
	return ($request, $request_line, $range);
}

sub write_full_response {
	my ($request) = @_;

	write_all($request, "HTTP/1.1 200 OK\r\n" .
		"Content-Length: " . length($pack) . "\r\n" .
		"Connection: close\r\n\r\n" . $pack);
}

sub write_resume_response {
	my ($request, $start, $reported_start) = @_;
	my $remaining = length($pack) - $start;
	my $end = length($pack) - 1;

	write_all($request, "HTTP/1.1 206 Partial Content\r\n" .
		"Content-Length: $remaining\r\n" .
		"Content-Range: bytes $reported_start-$end/" . length($pack) . "\r\n" .
		"Connection: close\r\n\r\n" . substr($pack, $start));
}

if ($mode eq "interrupted-resume") {
	my ($initial, undef, $initial_range) = accept_request();
	$initial_range eq "" or die "unexpected initial range: $initial_range";
	write_all($initial, "HTTP/1.1 200 OK\r\n" .
		"Content-Length: " . length($pack) . "\r\n" .
		"Connection: close\r\n\r\n" . substr($pack, 0, $cutoff));
	close($initial) or die "close interrupted response: $!";

	my ($resumed, undef, $range) = accept_request();
	print $result "$range\n" or die "write $result_path: $!";
	$range eq "bytes=$cutoff-" or die "unexpected resume range: $range";
	write_resume_response($resumed, $cutoff, $cutoff);
	close($resumed) or die "close resumed response: $!";
} elsif ($mode eq "ignore-range" || $mode eq "invalid-range") {
	my ($request, undef, $range) = accept_request();
	print $result "$range\n" or die "write $result_path: $!";
	$range eq "bytes=$cutoff-" or die "unexpected resume range: $range";
	if ($mode eq "ignore-range") {
		write_full_response($request);
	} else {
		write_resume_response($request, $cutoff, $cutoff - 1);
	}
	close($request) or die "close invalid response: $!";
} elsif ($mode eq "complete-no-range" ||
	 $mode eq "invalid-complete-range") {
	my ($request, undef, $range) = accept_request();
	my $expected_range = "bytes=" . length($pack) . "-";
	print $result "$range\n" or die "write $result_path: $!";
	$range eq $expected_range or die "unexpected complete range: $range";
	my $content_range = $mode eq "invalid-complete-range" ?
		"Content-Range: bytes */" . (length($pack) - 1) . "\r\n" : "";
	write_all($request, "HTTP/1.1 416 Range Not Satisfiable\r\n" .
		$content_range .
		"Content-Length: 0\r\nConnection: close\r\n\r\n");
	close($request) or die "close complete response: $!";
} elsif ($mode eq "no-response-retry" || $mode eq "headers-stall-retry") {
	my ($stalled, undef, $initial_range) = accept_request();
	$initial_range eq "" or die "unexpected initial range: $initial_range";
	if ($mode eq "headers-stall-retry") {
		write_all($stalled, "HTTP/1.1 200 OK\r\n" .
			"Content-Length: " . length($pack) . "\r\n" .
			"Connection: close\r\n\r\n");
	}

	my @ready = IO::Select->new($server)->can_read(5);
	@ready or die "$mode response was not retried";
	my ($retry, undef, $retry_range) = accept_request();
	$retry_range eq "" or die "unexpected retry range: $retry_range";
	print $result "retried\n" or die "write $result_path: $!";
	close($stalled) or die "close stalled response: $!";
	write_full_response($retry);
	close($retry) or die "close retry response: $!";
} elsif ($mode eq "redirect-target-failure-retry") {
	my ($initial, undef, $initial_range) = accept_request();
	$initial_range eq "" or die "unexpected initial range: $initial_range";
	my $redirect_server = IO::Socket::INET->new(
		LocalAddr => "127.0.0.1",
		LocalPort => 0,
		Proto => "tcp",
		Listen => 1,
		ReuseAddr => 1,
	) or die "listen for redirect: $!";
	my $redirect_port = $redirect_server->sockport();
	write_all($initial, "HTTP/1.1 302 Found\r\n" .
		"Location: http://127.0.0.1:$redirect_port/pack\r\n" .
		"Content-Length: 0\r\nConnection: close\r\n\r\n");
	close($initial) or die "close redirect response: $!";

	my $redirect = $redirect_server->accept()
		or die "accept redirected request: $!";
	<$redirect> or die "read redirected request: $!";
	close($redirect) or die "close redirected request: $!";
	close($redirect_server) or die "close redirect listener: $!";

	my @ready = IO::Select->new($server)->can_read(5);
	@ready or die "redirect target failure was not retried";
	my ($retry, undef, $retry_range) = accept_request();
	$retry_range eq "" or die "unexpected retry range: $retry_range";
	print $result "retried\n" or die "write $result_path: $!";
	write_full_response($retry);
	close($retry) or die "close retry response: $!";
} elsif ($mode eq "partial-stall-resume") {
	my ($stalled, undef, $initial_range) = accept_request();
	$initial_range eq "" or die "unexpected initial range: $initial_range";
	write_all($stalled, "HTTP/1.1 200 OK\r\n" .
		"Content-Length: " . length($pack) . "\r\n" .
		"Connection: close\r\n\r\n" . substr($pack, 0, $cutoff));

	my @ready = IO::Select->new($server)->can_read(5);
	@ready or die "partial response was not retried";
	my ($resumed, undef, $range) = accept_request();
	print $result "$range\n" or die "write $result_path: $!";
	$range eq "bytes=$cutoff-" or die "unexpected resume range: $range";
	close($stalled) or die "close stalled response: $!";
	write_resume_response($resumed, $cutoff, $cutoff);
	close($resumed) or die "close resumed response: $!";
} elsif ($mode eq "slow-progress") {
	my ($request, undef, $range) = accept_request();
	$range eq "" or die "unexpected initial range: $range";
	write_all($request, "HTTP/1.1 200 OK\r\n" .
		"Content-Length: " . length($pack) . "\r\n" .
		"Connection: close\r\n\r\n");
	my $chunk_size = int((length($pack) + 7) / 8);
	for (my $offset = 0; $offset < length($pack); $offset += $chunk_size) {
		my $length = $chunk_size;
		$length = length($pack) - $offset
			if $offset + $length > length($pack);
		write_all($request, substr($pack, $offset, $length));
		select(undef, undef, undef, 0.5)
			if $offset + $length < length($pack);
	}
	print $result "completed\n" or die "write $result_path: $!";
	close($request) or die "close progressing response: $!";
} elsif ($mode eq "delayed-proxy") {
	my ($request, $request_line, $range) = accept_request();
	$request_line =~ /^CONNECT deadline\.invalid:443 HTTP\/1\.[01]\r?\n$/
		or die "unexpected proxy request: $request_line";
	$range eq "" or die "unexpected proxy range: $range";
	select(undef, undef, undef, 2.0);
	my @readable = IO::Select->new($request)->can_read(0);
	my $alive = 1;
	if (@readable) {
		my $read = sysread($request, my $byte, 1);
		$alive = 0 if defined($read) && $read == 0;
	}
	print $result($alive ? "alive\n" : "closed\n")
		or die "write $result_path: $!";
	write_all($request, "HTTP/1.1 502 Bad Gateway\r\n" .
		"Content-Length: 0\r\nConnection: close\r\n\r\n") if $alive;
	close($request) or die "close proxy request: $!";
} else {
	die "unknown mode: $mode";
}

close($result) or die "close $result_path: $!";
close($server) or die "close listener: $!";
$completed = 1;
alarm 0;
