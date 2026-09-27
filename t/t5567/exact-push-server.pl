use strict;
use warnings;
use IO::Socket::INET;

# Each case supplies an initial advertisement and an exact response. Requests
# are saved before replying so tests can distinguish rejection from a push.
my ($root, $ready) = @ARGV;
my $listening = 0;
END {
	if (!$listening && defined($ready)) {
		open(my $out, '>', $ready) or die "open $ready: $!";
		print $out "failed\n";
	}
}
$SIG{TERM} = sub { exit 0 };
$SIG{ALRM} = sub { die "HTTP request timed out\n" };

sub read_file {
	my ($path) = @_;
	open(my $in, '<:raw', $path) or die "open $path: $!";
	return do { local $/; <$in> };
}

sub write_file {
	my ($path, $data) = @_;
	open(my $out, '>:raw', $path) or die "open $path: $!";
	print $out $data or die "write $path: $!";
	close($out) or die "close $path: $!";
}

sub packet {
	my ($data) = @_;
	return sprintf('%04x', length($data) + 4) . $data;
}

# Return packet contents and the offset after the final flush. The remaining
# bytes in a receive-pack request are the PACK, not packet lines.
sub packets {
	my ($body) = @_;
	my @lines;
	my $pos = 0;
	while ($pos + 4 <= length($body)) {
		my $header = substr($body, $pos, 4);
		$header =~ /^[0-9a-f]{4}$/ or die "invalid packet header";
		my $len = hex($header);
		$pos += 4;
		return (\@lines, $pos) if !$len;
		if ($len == 1) {
			push @lines, 'DELIM';
			next;
		}
		$len >= 4 && $pos + $len - 4 <= length($body)
			or die "truncated packet";
		my $line = substr($body, $pos, $len - 4);
		$line =~ s/\n$//;
		push @lines, $line;
		$pos += $len - 4;
	}
	die "missing packet flush";
}

sub read_bytes {
	my ($client, $length) = @_;
	my $data = '';
	while (length($data) < $length) {
		my $n = read($client, my $part, $length - length($data));
		defined($n) && $n > 0 or die "truncated HTTP request";
		$data .= $part;
	}
	return $data;
}

sub reply {
	my ($client, $status, $type, $body, $extra) = @_;
	print $client "HTTP/1.1 $status\r\n",
		"Content-Type: $type\r\n",
		'Content-Length: ', length($body), "\r\n",
		"Connection: close\r\n", ($extra || ''), "\r\n", $body
		or die "write HTTP response: $!";
}

my $algo = read_file("$root/algo");
chomp($algo);
my $zero = '0' x ($algo eq 'sha256' ? 64 : 40);
my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1',
	LocalPort => 0, Proto => 'tcp', Listen => 5, ReuseAddr => 1)
	or die "listen: $!";
write_file($ready, $server->sockport() . "\n");
$listening = 1;

while (my $client = $server->accept()) {
	alarm 30;
	$client->autoflush(1);
	binmode($client);
	my $request = <$client>;
	defined($request) or die "missing HTTP request";
	my ($method, $path) = split / /, $request;
	my %headers;
	while (my $line = <$client>) {
		last if $line =~ /^\r?\n$/;
		$line =~ /^([^:]+):\s*(.*?)\r?\n$/
			or die "invalid HTTP header";
		$headers{lc($1)} = $2;
	}
	my $body = '';
	if (($headers{'transfer-encoding'} || '') eq 'chunked') {
		while (1) {
			my $line = <$client>;
			defined($line) && $line =~ /^([0-9a-f]+)\r?\n$/i
				or die "invalid HTTP chunk";
			my $len = hex($1);
			last if !$len;
			$body .= read_bytes($client, $len);
			read_bytes($client, 2) eq "\r\n" or die "missing chunk CRLF";
		}
		read_bytes($client, 2) eq "\r\n" or die "missing chunk trailer";
	} elsif (exists($headers{'content-length'})) {
		$body = read_bytes($client, $headers{'content-length'});
	}
	$path =~ m{^/([a-z0-9_-]+)/(repo|session)/(info/refs\?service=git-receive-pack|git-upload-pack|git-receive-pack)$}
		or die "unexpected request: $request";
	my ($case, $location, $service) = ($1, $2, $3);
	my $dir = "$root/$case";
	open(my $log, '>>', "$dir/requests") or die "open requests: $!";
	print $log "$method $path\n";
	close($log);
	my $mode = read_file("$dir/mode");
	chomp($mode);
	if ($location eq 'repo') {
		$method eq 'GET' or die "POST did not use redirected session URL";
		reply($client, '307 Temporary Redirect', 'text/plain', '',
			"Location: http://127.0.0.1:" . $server->sockport() .
			"/$case/session/$service\r\n");
	} elsif ($method eq 'GET') {
		my @refs = split /\n/, read_file("$dir/initial");
		@refs = ("$zero capabilities^{}") unless @refs;
		my $caps = "report-status delete-refs ofs-delta object-format=$algo";
		$caps .= ' explicit-haves' unless $mode eq 'no-explicit-haves';
		$caps .= ' pando-exact-refs' unless $mode eq 'stock';
		$refs[0] .= "\0$caps";
		my $advertisement = packet("# service=git-receive-pack\n") . '0000';
		$advertisement .= packet("$_\n") for @refs;
		$advertisement .= '0000';
		reply($client, '200 OK', 'application/x-git-receive-pack-advertisement',
			$advertisement);
	} elsif ($service eq 'git-upload-pack') {
		write_file("$dir/query-header", ($headers{'git-protocol'} || '') . "\n");
		my ($lines, $end) = packets($body);
		$end == length($body) or die "trailing query bytes";
		write_file("$dir/query", join("\n", @$lines) . "\n");
		my @refs = split /\n/, read_file("$dir/exact");
		my $response = join('', map { packet("$_\n") } @refs) . '0000';
		$response = packet("$refs[0]\n") . $response if $mode eq 'duplicate';
		$response = packet("$zero refs/heads/unrequested\n") . $response
			if $mode eq 'extra';
		$response = packet("not-an-object-id refs/heads/topic\n") . '0000'
			if $mode eq 'bad-oid';
		$response = $response x 100 if $mode eq 'oversized';
		$response = substr($response, 0, -4) if $mode eq 'truncated';
		$response .= 'unexpected' if $mode eq 'trailing';
		$response = packet("ERR exact refs unavailable\n") . '0000'
			if $mode eq 'error';
		my $status = $mode eq 'http-error' ? '400 Bad Request' : '200 OK';
		reply($client, $status, 'application/x-git-upload-pack-result', $response);
	} elsif ($service eq 'git-receive-pack') {
		write_file("$dir/receive-body", $body);
		my ($lines, $end) = packets($body);
		my @commands;
		my $result = packet("unpack ok\n");
		for my $line (@$lines) {
			my ($command, $caps) = split /\0/, $line, 2;
			write_file("$dir/receive-capabilities", "$caps\n") if defined($caps);
			push @commands, $command;
			my ($old, $new, $name) = split / /, $command;
			defined($name) or die "invalid receive command";
			$result .= $mode eq 'receive-reject'
				? packet("ng $name exact contract unavailable\n")
				: packet("ok $name\n");
		}
		write_file("$dir/commands", join("\n", @commands) . "\n");
		write_file("$dir/pack", substr($body, $end));
		reply($client, '200 OK', 'application/x-git-receive-pack-result',
			$result . '0000');
	} else {
		die "unexpected request: $request";
	}
	close($client);
	alarm 0;
}
