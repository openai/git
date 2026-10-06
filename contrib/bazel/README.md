# Bazel

Build Git with Bazel 8.5 or newer. On Linux and Windows, use Clang/LLD;
for example, `bazel build -c opt --extra_toolchains=@llvm//toolchain:all //:git`.
On macOS, `bazel build -c opt //:git` uses the installed Apple toolchain.
Windows uses the GNU ABI and requires Git Bash. The module does not register
C/C++ toolchains for its consumers.

Use a Bzlmod `archive_override` to pin a source revision and apply patches,
then depend on `@git//:git` and the required helper binaries. The `templates` and
`mergetools` filegroups expose runtime data. Installation and helper aliases
belong to the consumer; the compiled exec path is `libexec/git-core`.
Version generation uses Git's `DEF_VER` and reports an unknown commit.

The curl overlay adds HTTP/2 and GNU Windows support missing from the registry.
It derives from registry curl 8.22.0 at
45818418a9b9c70bc0afc3144cb9dd8cab86c0b7. Platform configuration derives in part
from registry Git 2.55.0 at eba513313039158442b2a7dc3f3d1b2880b86675.
`LICENSE.registry` retains the Apache 2.0 license for these build definitions.
