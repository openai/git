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
elif test "$status" = ignore-range || test "$status" = wrong-range
then
	size=$(wc -c <"www$PATH_INFO")
	if test "$status" = wrong-range
	then
		printf "HTTP/1.1 206 Partial Content\r\nConnection: close\r\n"
		printf "Content-Range: bytes 0-%s/%s\r\n" "$((size - 1))" "$size"
	else
		printf "HTTP/1.1 200 OK\r\nConnection: close\r\n"
	fi
	printf "Content-Type: application/x-git-packed-objects\r\n"
	printf "Content-Length: %s\r\n\r\n" "$size"
	cat "www$PATH_INFO"
elif test "$status" = truncated || test "$status" = empty
then
	size=$(wc -c <"www$PATH_INFO")
	offset=${HTTP_RANGE#bytes=}
	offset=${offset%-}
	offset=${offset:-0}
	if test "$offset" = 0
	then
		printf "HTTP/1.1 200 OK\r\nConnection: close\r\n"
	else
		printf "HTTP/1.1 206 Partial Content\r\nConnection: close\r\n"
		printf "Content-Range: bytes %s-%s/%s\r\n" \
			"$offset" "$((size - 1))" "$size"
	fi
	printf "Content-Type: application/x-git-packed-objects\r\n"
	printf "Content-Length: %s\r\n\r\n" "$((size - offset))"
	if test "$status" = truncated
	then
		dd if="www$PATH_INFO" bs=1 skip="$offset" count=12
	fi
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
