# Bazel

These targets are consumed from a source archive using `http_archive`.
Pin the source revision and apply local patches in the consuming workspace.
Build `@git//:git` and the required helper targets; `templates` and `mergetools`
provide runtime data. Installation and helper aliases belong to the consumer.

The consumer supplies `rules_cc`, `rules_shell`, `platforms`, `curl`, `libexpat`,
`openssl`, `pcre2`, and `zlib-ng` (the `zlib_ng_native` target). Windows also
requires `win_iconv` and `llvm` for its resource compiler, plus Git Bash.
Use Clang/LLD on Linux and Windows (GNU ABI), and the Apple toolchain on macOS.
The compiled exec path is `libexec/git-core`; version generation uses Git's
`DEF_VER` and reports an unknown commit.

Platform configuration is adapted in part from the Bazel Central Registry's
Git 2.55.0 overlay at eba513313039158442b2a7dc3f3d1b2880b86675.
`LICENSE.registry` retains its Apache 2.0 license.
