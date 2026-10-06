#include <stdio.h>
#include <curl/curl.h>

int main(void)
{
	const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
	const int required = CURL_VERSION_SSL | CURL_VERSION_IPV6 |
		CURL_VERSION_ASYNCHDNS;

	if ((info->features & required) != required) {
		fprintf(stderr, "missing transport features: %x (%s)\n",
			required & ~info->features, curl_version());
		return 1;
	}
	puts(curl_version());
	return 0;
}
