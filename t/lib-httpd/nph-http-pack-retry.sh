#!/bin/sh

# Consume one "status [Retry-After]" line per request. A 200 redirects to
# Apache so that the successful response supports byte ranges.
read status retry_after <pack-retry.responses
sed 1d pack-retry.responses >pack-retry.next &&
mv pack-retry.next pack-retry.responses || exit 1
printf "%s|%s|%s\n" "$REQUEST_METHOD" "$HTTP_RANGE" \
	"$HTTP_AUTHORIZATION" >>pack-retry.requests

if test "$status" = 200
then
	printf "HTTP/1.1 302 Found\r\nConnection: close\r\n"
	printf "Location: /dumb%s\r\n\r\n" "$PATH_INFO"
elif test "$status" = truncated
then
	printf "HTTP/1.1 200 OK\r\nConnection: close\r\n"
	printf "Content-Type: application/x-git-packed-objects\r\n"
	printf "Content-Length: 1000\r\n\r\n"
	dd if="www$PATH_INFO" bs=1 count=12
else
	printf "HTTP/1.1 %s Test failure\r\nConnection: close\r\n" "${status:-500}"
	if test -n "$retry_after"
	then
		printf "Retry-After: %s\r\n" "$retry_after"
	fi
	if test "$status" = 401
	then
		printf "WWW-Authenticate: Bearer realm=pack\r\n"
	fi
	printf "Content-Type: text/plain\r\n\r\nNot a packfile\n"
fi
