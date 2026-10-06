load("@rules_cc//cc:cc_binary.bzl", "cc_binary")

# Platform configuration follows config.mak.uname and the Makefile.
# Adapted in part from the registry Git overlay; see LICENSE.registry.

_GIT_BASE_COPTS = [
    "-Wall",
    "-DUSE_CURL_FOR_IMAP_SEND",
    "-DSUPPORTS_SIMPLE_IPC",
    "-DSHA1_DC",
    "-DSHA1DC_NO_STANDARD_INCLUDES",
    "-DSHA1DC_INIT_SAFE_HASH_DEFAULT=0",
    '-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\\"git-compat-util.h\\"',
    '-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\\"git-compat-util.h\\"',
    "-DSHA256_BLK",
    '-DSHELL_PATH=\\"/bin/sh\\"',
    '-DGIT_HTML_PATH=\\"share/doc/git-doc\\"',
    '-DGIT_MAN_PATH=\\"share/man\\"',
    '-DGIT_INFO_PATH=\\"share/info\\"',
    '-DGIT_LOCALE_PATH=\\"share/locale\\"',
    '-DBINDIR=\\"bin\\"',
    '-DFALLBACK_RUNTIME_PREFIX=\\"\\"',
    '-DDEFAULT_GIT_TEMPLATE_DIR=\\"share/git-core/templates\\"',
    '-DPAGER_ENV=\\"LESS=FRX\\\\040LV=-c\\"',
    "-DNO_GETTEXT",
    "-DHAVE_ZLIB_NG",
    "-DUSE_LIBPCRE2",
]

_GIT_CPU_DEFINES = select({
    "@platforms//cpu:aarch64": ['-DGIT_HOST_CPU=\\"aarch64\\"'],
    "@platforms//cpu:x86_64": ['-DGIT_HOST_CPU=\\"x86_64\\"'],
    "//conditions:default": ['-DGIT_HOST_CPU=\\"unknown\\"'],
})

_GIT_MACOS_ICONV_COPTS = [
    # v2.53.0: Work around broken system iconv on newer macOS versions.
    "-DICONV_RESTART_RESET",
]

_GIT_MACOS_ICONV_LINKOPTS = [
    "-liconv",
]

_GIT_OS_DEFINES = select({
    "@platforms//os:linux": [
        "-DHAVE_ALLOCA_H",
        "-DHAVE_PATHS_H",
        "-DHAVE_DEV_TTY",
        "-DHAVE_CLOCK_GETTIME",
        "-DHAVE_CLOCK_MONOTONIC",
        "-DHAVE_SYNC_FILE_RANGE",
        "-DHAVE_SYSINFO",
        "-DHAVE_LINUX_MAGIC_H",
        "-DHAVE_PLATFORM_PROCINFO",
        "-DHAVE_GETDELIM",
        "-DHAVE_GETRANDOM",
        "-DFREAD_READS_DIRECTORIES",
        "-DNO_STRLCPY",
        "-DRUNTIME_PREFIX",
        '-DPROCFS_EXECUTABLE_PATH=\\"/proc/self/exe\\"',
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
    ],
    "@platforms//os:macos": [
        "-DHAVE_PATHS_H",
        "-DHAVE_DEV_TTY",
        "-DHAVE_PLATFORM_PROCINFO",
        "-DHAVE_GETDELIM",
        "-DFREAD_READS_DIRECTORIES",
        "-DNO_MEMMEM",
        "-DUSE_ST_TIMESPEC",
        "-DPRECOMPOSE_UNICODE",
        "-DPROTECT_HFS_DEFAULT=1",
        "-DHAVE_BSD_SYSCTL",
        "-DHAVE_NS_GET_EXECUTABLE_PATH",
        "-DRUNTIME_PREFIX",
        "-DUSE_ENHANCED_BASIC_REGULAR_EXPRESSIONS",
        "-DHAVE_ARC4RANDOM",
        # fsmonitor
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
    ] + _GIT_MACOS_ICONV_COPTS,
    "@platforms//os:windows": [
        # fsmonitor
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
        "-DNO_OPENSSL",
        "-DPCRE2_STATIC",
        "-DHAVE_ALLOCA_H",
        "-DHAVE_WPGMPTR",
        "-DRUNTIME_PREFIX",
        "-DNO_PREAD",
        "-DNO_WRITEV",
        "-DNO_LIBGEN_H",
        "-DNO_POLL",
        "-DNO_POLL_H",
        "-DNO_SYS_POLL_H",
        "-DNO_SYMLINK_HEAD",
        "-DNO_SETENV",
        "-DNO_STRCASESTR",
        "-DNO_STRLCPY",
        "-DNO_MEMMEM",
        "-DNO_STRTOUMAX",
        "-DNO_MKDTEMP",
        "-DNO_ST_BLOCKS_IN_STRUCT_STAT",
        "-DUSE_WIN32_IPC",
        "-DUSE_WIN32_MMAP",
        "-DMMAP_PREVENTS_DELETE",
        "-DUNRELIABLE_FSTAT",
        "-DOBJECT_CREATION_MODE=1",
        "-DNO_POSIX_GOODIES",
        "-DHAVE_PLATFORM_PROCINFO",
        "-DHAVE_RTLGENRANDOM",
        "-DNOGDI",
        "-DWIN32",
        "-DNATIVE_CRLF",
        "-DDETECT_MSYS_TTY",
        "-D__USE_MINGW_ANSI_STDIO=0",
        '-DSTRIP_EXTENSION=\\".exe\\"',
    ],
    "//conditions:default": [],
})

_GIT_RUNTIME_PATH_DEFINES = select({
    "@platforms//os:windows": [
        '-DGIT_EXEC_PATH=\\"libexec/git-core\\"',
        '-DETC_GITCONFIG=\\"etc/gitconfig\\"',
        '-DETC_GITATTRIBUTES=\\"etc/gitattributes\\"',
    ],
    "//conditions:default": [
        '-DGIT_EXEC_PATH=\\"libexec/git-core\\"',
        '-DETC_GITCONFIG=\\"/etc/gitconfig\\"',
        '-DETC_GITATTRIBUTES=\\"/etc/gitattributes\\"',
    ],
})

GIT_COPTS = _GIT_BASE_COPTS + _GIT_CPU_DEFINES + _GIT_OS_DEFINES + _GIT_RUNTIME_PATH_DEFINES

GIT_LINKOPTS = select({
    "@platforms//os:linux": ["-lpthread", "-ldl", "-lm", "-lrt", "-lutil"],
    "@platforms//os:macos": [
        "-lpthread",
        "-framework",
        "CoreServices",
    ] + _GIT_MACOS_ICONV_LINKOPTS,
    "@platforms//os:windows": ["-municode", "-lws2_32", "-lntdll"],
    "//conditions:default": [],
})

def git_binary(name, srcs, deps = []):
    cc_binary(
        name = name,
        srcs = ["common-main.c"] + srcs,
        copts = GIT_COPTS,
        linkopts = GIT_LINKOPTS,
        deps = [":libgit"] + deps + select({
            "@platforms//os:windows": [":windows_resources"],
            "//conditions:default": [],
        }),
    )
