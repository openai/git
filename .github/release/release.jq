# JSON validation and record construction for release.sh. Git and GitHub
# operations stay in the shell script; this file only transforms data.
def require($ok; $message): if $ok then . else error($message) end;
def oid: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
def name: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
def repository: type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");
def branch: type == "string" and test("^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$");
def positive_integer: type == "number" and . > 0 and . == floor;
def checksum: type == "string" and test("^[0-9a-f]{64}$");
def targets: ["macOS-arm64", "macOS-x64", "ubuntu-arm64", "ubuntu-x64", "windows-arm64", "windows-x64"];
def archive_names($version; $target):
  ["tar.gz", "lzma"] | map("git-\($version)-\($target).\(.)");
def asset_names($version; $target):
  archive_names($version; $target) | map([., . + ".sha256"]) | add;

def topics_for($channel):
  . as $config |
  reduce .channels[$channel].topic_sets[] as $set
    ([]; require(($config.topic_sets[$set] | type) == "array"; "unknown topic set") |
     . + $config.topic_sets[$set]) |
  reduce .[] as $input ({seen: {}, topics: []};
    ($input + {dependency: ($input.dependency // "release-base")}) as $topic |
    require(($topic.name | name) and $topic.name != "release-base" and
            (.seen | has($topic.name) | not); "duplicate or invalid topic name") |
    require(($topic.source_sha | oid) and ($topic.source_base | oid) and
            ($topic.source_ref | branch) and ($topic.review_pr | positive_integer);
            "topics need a full source pin, boundary, branch, and source review") |
    require($topic.dependency == "release-base" or (.seen | has($topic.dependency));
            "topics must follow their prerequisites") |
    require($topic.dependency == "release-base" or
            $topic.source_base == .seen[$topic.dependency].source_sha;
            "dependent topic must pin its prerequisite boundary") |
    .seen[$topic.name] = $topic | .topics += [$topic]) | .topics;

def validate_config:
  require(.schema_version == 1; "unsupported release configuration") |
  require((.repository | repository) and (.recipe_repository | repository);
          "invalid repository") |
  require(.visibility == "public" or .visibility == "private"; "invalid visibility") |
  require((.control_ref | branch) and (.catalog_ref | branch) and
          .control_ref != .catalog_ref; "invalid controller refs") |
  require((has("recipe_sha") | not) or (.recipe_sha | oid); "invalid recipe pin") |
  require((.channels | type) == "object" and (.channels | length) > 0;
          "release channels are missing") |
  . as $config |
  reduce (.channels | to_entries[]) as $entry (.;
    $entry.key as $channel | $entry.value as $lane |
    require(($channel | name) and $lane.ref == "refs/heads/" + $channel and
            $lane.ref != .control_ref and $lane.ref != .catalog_ref;
            "channel/ref mismatch") |
    require(($lane.enabled | type) == "boolean" and ($lane.prerelease | type) == "boolean";
            "channel switches must be booleans") |
    require(($lane.build_revision // 1 | positive_integer); "invalid build revision") |
    if $lane.kind == "overlay" then
      require(.visibility == "private" and (.recipe_sha | oid);
              "topic overlays require a private repository and pinned recipe") |
      require(($lane.upstream.repository | repository) and ($lane.upstream.channel | name);
              "invalid upstream channel") |
      ($config | topics_for($channel)) as $topics | .
    else
      require($lane.kind == "ledger" and ($lane.build_revision // 1) == 1;
              "invalid ledger channel") |
      require(($lane.ledger_path | type) == "string" and
              ($lane.ledger_path | test("^[A-Za-z0-9._/-]+$")) and
              ($lane.ledger_key | type) == "string" and
              ($lane.ledger_key | test("^[A-Za-z0-9.-]+$")); "invalid ledger field")
    end);

def inputs:
  {repository, visibility, channel, recipe, base, topics, build_revision};

def validate_manifest($repo; $channel):
  require(.schema_version == 1 and .repository == $repo and .channel == $channel;
          "manifest belongs to another repository or channel") |
  require((.source_sha | oid) and (.recipe.sha | oid) and
          (.recipe.repository | repository) and (.version | name);
          "invalid manifest source or recipe") |
  require(.visibility == "public" or .visibility == "private"; "invalid manifest visibility") |
  require((.targets | keys | sort) == (targets | sort); "release must contain all six targets") |
  .version as $version |
  reduce (.targets | to_entries[]) as $target (.;
    require(($target.value | length) == 4 and
            ([$target.value[].name] | sort) == (asset_names($version; $target.key) | sort);
            "incomplete or duplicate target assets") |
    require(all($target.value[]; (.size | positive_integer) and (.sha256 | checksum));
            "invalid asset size or checksum"));

def manifest_from($candidate; $records):
  $candidate | {schema_version, repository, visibility, channel, version,
    source_sha, upstream_tag, recipe, base, topics, build_revision, control_sha, inputs_sha256} |
  . + {targets: {}, builds: {}} |
  reduce $records[] as $record (.;
    require(($record.target as $t | targets | index($t)) != null;
            "unknown native target") |
    require($record.repository == $candidate.repository and
            $record.version == $candidate.version and
            $record.source_sha == $candidate.source_sha and
            $record.recipe == $candidate.recipe and $record.run_id == $candidate.run_id;
            "build source, recipe, or workflow run differs from candidate") |
    .targets[$record.target] = $record.assets | .builds[$record.target] = $record) |
  validate_manifest($candidate.repository; $candidate.channel);

def verify_asset_metadata($manifest):
  [$manifest.targets[][]] as $expected |
  require(([.assets[].name] | sort) == (([$expected[].name] + ["manifest.json"]) | sort);
          "published asset set is incomplete") |
  require(all(.assets[] | select(.name != "manifest.json");
    . as $actual | $expected[] | select(.name == $actual.name) |
    .size == $actual.size and
    (($actual.digest // "") == "" or $actual.digest == "sha256:" + .sha256));
    "published asset size or digest changed");
