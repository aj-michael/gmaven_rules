# rules_jvm_external

Transitive Maven artifact resolution and publishing rules for Bazel.

[![Build
Status](https://badge.buildkite.com/26d895f5525652e57915a607d0ecd3fc945c8280a0bdff83d9.svg?branch=master)](https://buildkite.com/bazel/rules-jvm-external)


Table of Contents
=================

   * [rules_jvm_external](#rules_jvm_external)
      * [Features](#features)
      * [Usage](#usage)
      * [API Reference](#api-reference)
      * [Pinning artifacts and integration with Bazel's downloader](#pinning-artifacts-and-integration-with-bazels-downloader)
         * [Updating maven_install.json](#updating-maven_installjson)
         * [Custom location for maven_install.json](#custom-location-for-maven_installjson)
         * [Multiple maven_install.json files](#multiple-maven_installjson-files)
      * [Generated targets](#generated-targets)
      * [Outdated artifacts](#outdated-artifacts)
      * [Advanced usage](#advanced-usage)
         * [Fetch source JARs](#fetch-source-jars)
         * [Checksum verification](#checksum-verification)
         * [Using a persistent artifact cache](#using-a-persistent-artifact-cache)
         * [artifact helper macro](#artifact-helper-macro)
         * [Multiple maven_install declarations for isolated artifact version trees](#multiple-maven_install-declarations-for-isolated-artifact-version-trees)
         * [Detailed dependency information specifications](#detailed-dependency-information-specifications)
         * [Artifact exclusion](#artifact-exclusion)
         * [Compile-only dependencies](#compile-only-dependencies)
         * [Resolving user-specified and transitive dependency version conflicts](#resolving-user-specified-and-transitive-dependency-version-conflicts)
         * [Overriding generated targets](#overriding-generated-targets)
         * [Proxies](#proxies)
         * [Repository aliases](#repository-aliases)
            * [Repository remapping](#repository-remapping)
         * [Hiding transitive dependencies](#hiding-transitive-dependencies)
         * [Fetch and resolve timeout](#fetch-and-resolve-timeout)
         * [Jetifier](#jetifier)
      * [Exporting and consuming artifacts from external repositories](#exporting-and-consuming-artifacts-from-external-repositories)
      * [Publishing to external repositories](#publishing-to-external-repositories)
      * [Demo](#demo)
      * [Projects using rules_jvm_external](#projects-using-rules_jvm_external)
      * [Generating documentation](#generating-documentation)

## Features

* WORKSPACE configuration
* JAR, AAR, source JARs
* Custom Maven repositories
* Private Maven repositories with HTTP Basic Authentication
* Artifact version resolution with Coursier
* Integration with Bazel's downloader and caching mechanisms for sharing artifacts across Bazel workspaces
* Pin resolved artifacts with their SHA-256 checksums into a version-controllable JSON file
* Versionless target labels for simpler dependency management
* Ability to declare multiple sets of versioned artifacts
* Supported on Windows, macOS, Linux

Get the [latest release
here](https://github.com/bazelbuild/rules_jvm_external/releases/latest).

## Usage

List the top-level Maven artifacts and servers in the WORKSPACE:

```python
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

RULES_JVM_EXTERNAL_TAG = "4.0"
RULES_JVM_EXTERNAL_SHA = "31701ad93dbfe544d597dbe62c9a1fdd76d81d8a9150c2bf1ecf928ecdf97169"

http_archive(
    name = "rules_jvm_external",
    strip_prefix = "rules_jvm_external-%s" % RULES_JVM_EXTERNAL_TAG,
    sha256 = RULES_JVM_EXTERNAL_SHA,
    url = "https://github.com/bazelbuild/rules_jvm_external/archive/%s.zip" % RULES_JVM_EXTERNAL_TAG,
)

load("@rules_jvm_external//:defs.bzl", "maven_install")

maven_install(
    artifacts = [
        "junit:junit:4.12",
        "androidx.test.espresso:espresso-core:3.1.1",
        "org.hamcrest:hamcrest-library:1.3",
    ],
    repositories = [
        # Private repositories are supported through HTTP Basic auth
        "http://username:password@localhost:8081/artifactory/my-repository",
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
)
```

Credentials for private repositories can also be specified using a property file
or environment variables. See the [Coursier
documentation](https://get-coursier.io/docs/other-credentials.html#property-file)
for more information.

`rules_jvm_external_setup` uses a default list of maven repositories to download
 `rules_jvm_external`'s own dependencies from. Should you wish to change this,
 use the `repositories` parameter:

 ```python
rules_jvm_external_setup(repositories = ["https://mycorp.com/artifacts"])
```

Next, reference the artifacts in the BUILD file with their versionless label:

```python
java_library(
    name = "java_test_deps",
    exports = [
        "@maven//:junit_junit",
        "@maven//:org_hamcrest_hamcrest_library",
    ],
)

android_library(
    name = "android_test_deps",
    exports = [
        "@maven//:junit_junit",
        "@maven//:androidx_test_espresso_espresso_core",
    ],
)
```

The default label syntax for an artifact `foo.bar:baz-qux:1.2.3` is `@maven//:foo_bar_baz_qux`. That is,

* All non-alphanumeric characters are substituted with underscores.
* Only the group and artifact IDs are required.
* The target is located in the `@maven` top level package (`@maven//`).

## API Reference

You can find the complete API reference at [docs/api.md](docs/api.md).

## Pinning artifacts and integration with Bazel's downloader

`rules_jvm_external` supports pinning artifacts and their SHA-256 checksums into
a `maven_install.json` file that can be checked into your repository.

Without artifact pinning, in a clean checkout of your project, `rules_jvm_external`
executes the full artifact resolution and fetching steps (which can take a bit of time)
and does not verify the integrity of the artifacts against their checksums. The
downloaded artifacts also cannot be shared across Bazel workspaces.

By pinning artifact versions, you can get improved artifact resolution and build times,
since using `maven_install.json` enables `rules_jvm_external` to integrate with Bazel's
downloader that caches files on their sha256 checksums. It also improves resiliency and
integrity by tracking the sha256 checksums and original artifact urls in the
JSON file.

Since all artifacts are persisted locally in Bazel's cache, it means that
**fully offline builds are possible** after the initial `bazel fetch @maven//...`.
The artifacts are downloaded with `http_file` which supports `netrc` for authentication.
Your `~/.netrc` will be included automatically.
For additional credentials, add them in the repository URLs passed to `maven_install`
(so they will be included in the generated JSON).
Alternatively, pass an array of `additional_netrc_lines` to `maven_install` for authentication with credentials from
outside the workspace.

To get started with pinning artifacts, run the following command to generate the
initial `maven_install.json` at the root of your Bazel workspace:

```
$ bazel run @maven//:pin
```

Then, specify `maven_install_json` in `maven_install` and load
`pinned_maven_install` from `@maven//:defs.bzl`:

```python
maven_install(
    # artifacts, repositories, ...
    maven_install_json = "//:maven_install.json",
)

load("@maven//:defs.bzl", "pinned_maven_install")
pinned_maven_install()
```

**Note:** The `//:maven_install.json` label assumes you have a BUILD file in
your project's root directory. If you do not have one, create an empty BUILD
file to fix issues you may see. See
[#242](https://github.com/bazelbuild/rules_jvm_external/issues/242)

**Note:** If you're using an older version of `rules_jvm_external` and
haven't repinned your dependencies, you may see a warning that you lock
file "does not contain a signature of the required artifacts" then don't
worry: either ignore the warning or repin the dependencies.

### Updating `maven_install.json`

Whenever you make a change to the list of `artifacts` or `repositories` and want
to update `maven_install.json`, run this command to re-pin the unpinned `@maven`
repository:

```
$ bazel run @unpinned_maven//:pin
```

Without re-pinning, `maven_install` will not pick up the changes made to the
WORKSPACE, as `maven_install.json` is now the source of truth.

Note that the repository is `@unpinned_maven` instead of `@maven`. When using
artifact pinning, each `maven_install` repository (e.g. `@maven`) will be
accompanied by an unpinned repository. This repository name has the `@unpinned_`
prefix (e.g.`@unpinned_maven` or `@unpinned_<your_maven_install_name>`). For
example, if your `maven_install` is named `@foo`, `@unpinned_foo` will be
created.

### Requiring lock file repinning when the list of artifacts changes

It can be easy to forget to update the `maven_install.json` lock file
when updating artifacts in a `maven_install`. Normally,
rules_jvm_external will print a warning to the console and continue
the build when this happens, but by setting the
`fail_if_repin_required` attribute to `True`, this will be treated as
a build error, causing the build to fail. When this attribute is set,
it is possible to update the `maven_install.json` file using:

```shell
# To repin everything:
REPIN=1 bazel run @unpinned_maven//:pin

# To only repin rules_jvm_external:
RULES_JVM_EXTERNAL_REPIN=1 bazel run @unpinned_maven//:pin
```

Alternatively, it is also possible to modify the
`fail_if_repin_required` attribute in your `WORKSPACE` file, run
`bazel run @unpinned_maven//:pin` and then reset the
`fail_if_repin_required` attribute.

### Custom location for `maven_install.json`

You can specify a custom location for `maven_install.json` by changing the
`maven_install_json` attribute value to point to the new file label. For example:

```python
maven_install(
    name = "maven_install_in_custom_location",
    artifacts = ["com.google.guava:guava:27.0-jre"],
    repositories = ["https://repo1.maven.org/maven2"],
    maven_install_json = "@rules_jvm_external//tests/custom_maven_install:maven_install.json",
)

load("@maven_install_in_custom_location//:defs.bzl", "pinned_maven_install")
pinned_maven_install()
```

Future artifact pinning updates to `maven_install.json` will overwrite the file
at the specified path instead of creating a new one at the default root
directory location.

### Multiple `maven_install.json` files

If you have multiple `maven_install` declarations, you have to alias
`pinned_maven_install` to another name to prevent redefinitions:

```python
maven_install(
    name = "foo",
    maven_install_json = "//:foo_maven_install.json",
    # ...
)

load("@foo//:defs.bzl", foo_pinned_maven_install = "pinned_maven_install")
foo_pinned_maven_install()

maven_install(
    name = "bar",
    maven_install_json = "//:bar_maven_install.json",
    # ...
)

load("@bar//:defs.bzl", bar_pinned_maven_install = "pinned_maven_install")
bar_pinned_maven_install()
```

## Generated targets

For the `junit:junit` example, using `bazel query @maven//:all --output=build`, we can see that the rule generated these targets:

```python
alias(
  name = "junit_junit_4_12",
  actual = "@maven//:junit_junit",
)

jvm_import(
  name = "junit_junit",
  jars = ["@maven//:https/repo1.maven.org/maven2/junit/junit/4.12/junit-4.12.jar"],
  srcjar = "@maven//:https/repo1.maven.org/maven2/junit/junit/4.12/junit-4.12-sources.jar",
  deps = ["@maven//:org_hamcrest_hamcrest_core"],
  tags = ["maven_coordinates=junit:junit:4.12"],
)

jvm_import(
  name = "org_hamcrest_hamcrest_core",
  jars = ["@maven//:https/repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar"],
  srcjar = "@maven//:https/repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3-sources.jar",
  deps = [],
  tags = ["maven_coordinates=org.hamcrest:hamcrest.library:1.3"],
)
```

These targets can be referenced by:

*   `@maven//:junit_junit`
*   `@maven//:org_hamcrest_hamcrest_core`

**Transitive classes**: To use a class from `hamcrest-core` in your test, it's not sufficient to just
depend on `@maven//:junit_junit` even though JUnit depends on Hamcrest. The compile classes are not exported
transitively, so your test should also depend on `@maven//:org_hamcrest_hamcrest_core`.

**Original coordinates**: The generated `tags` attribute value also contains the original coordinates of
the artifact, which integrates with rules like [bazel-common's
`pom_file`](https://github.com/google/bazel-common/blob/f1115e0f777f08c3cdb115526c4e663005bec69b/tools/maven/pom_file.bzl#L177)
for generating POM files. See the [`pom_file_generation`
example](examples/pom_file_generation/) for more information.

## Outdated artifacts

To check for updates of artifacts, run the following command at the root of your Bazel workspace:

```
$ bazel run @maven//:outdated
```

## Advanced usage

### Fetch source JARs

To download the source JAR alongside the main artifact JAR, set `fetch_sources =
True` in `maven_install`:

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    fetch_sources = True,
)
```

### Checksum verification

Artifact resolution will fail if a `SHA-1` or `MD5` checksum file for the
artifact is missing in the repository. To disable this behavior, set
`fail_on_missing_checksum = False` in `maven_install`:

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    fail_on_missing_checksum = False,
)
```

### Using a persistent artifact cache

> NOTE: Prefer using artifact pinning / maven_install.json instead. This
> is a caching mechanism that was implemented before artifact pinning,
> which uses Coursier's own persistent cache. With artifact pinning and
> maven_install.json, the persistent cache is integrated directly into
> Bazel's internal cache.

To download artifacts into a shared and persistent directory in your home
directory, set `use_unsafe_shared_cache = True` in `maven_install`.

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    use_unsafe_shared_cache = True,
)
```

This is **not safe** as Bazel is currently not able to detect changes in the
shared cache. For example, if an artifact is deleted from the shared cache,
Bazel will not re-run the repository rule automatically.

To change the location of the cache from the home directory, set the
`COURSIER_CACHE` environment variable. You can also use the `--repo_env` flag to
set the variable on the command line and in `.bazelrc` files:

```
$ bazel build @maven_with_unsafe_shared_cache//... --repo_env=COURSIER_CACHE=/tmp/custom_cache
```

This feature also enables checking the downloaded artifacts into your source
tree by declaring `COURSIER_CACHE` to be `<project root>/some/directory`. For
example:

```
$ bazel build @maven_with_unsafe_shared_cache//... --repo_env=COURSIER_CACHE=$(pwd)/third_party
```

The default value of `use_unsafe_shared_cache` is `False`. This means that Bazel
will create independent caches for each `maven_install` repository, located at
`$(bazel info output_base)/external/@<repository_name>/v1`.

### Using a custom Coursier download url

By default bazel bootstraps Coursier via [the urls specificed in versions.bzl](private/versions.bzl).
However in case they are not directly accessible in your environment, you can also specify a custom
url to download Coursier. For example:

```
$ bazel build @maven_with_unsafe_shared_cache//... --repo_env=COURSIER_URL='https://my_secret_host.com/vXYZ/coursier.jar'
```

Please note it still requires the SHA to match.

### `artifact` helper macro

The `artifact` macro translates the artifact's `group:artifact` coordinates to
the label of the versionless target. This target is an
[alias](https://docs.bazel.build/versions/master/be/general.html#alias) that
points to the `java_import`/`aar_import` target in the `@maven` repository,
which includes the transitive dependencies specified in the top level artifact's
POM file.

For example, `@maven//:junit_junit` is equivalent to `artifact("junit:junit")`.

To use it, add the load statement to the top of your BUILD file:

```python
load("@rules_jvm_external//:defs.bzl", "artifact")
```

Note that usage of this macro makes BUILD file refactoring with tools like
`buildozer` more difficult, because the macro hides the actual target label at
the syntax level.

### Multiple `maven_install` declarations for isolated artifact version trees

If your WORKSPACE contains several projects that use different versions of the
same artifact, you can specify multiple `maven_install` declarations in the
WORKSPACE, with a unique repository name for each of them.

For example, if you want to use the JRE version of Guava for a server app, and
the Android version for an Android app, you can specify two `maven_install`
declarations:

```python
maven_install(
    name = "server_app",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

maven_install(
    name = "android_app",
    artifacts = [
        "com.google.guava:guava:27.0-android",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)
```

This way, `rules_jvm_external` will invoke coursier to resolve artifact versions for
both repositories independent of each other. Coursier will fail if it encounters
version conflicts that it cannot resolve. The two Guava targets can then be used
in BUILD files like so:

```python
java_binary(
    name = "my_server_app",
    srcs = ...
    deps = [
        # a versionless alias to @server_app//:com_google_guava_guava_27_0_jre
        "@server_app//:com_google_guava_guava",
    ]
)

android_binary(
    name = "my_android_app",
    srcs = ...
    deps = [
        # a versionless alias to @android_app//:com_google_guava_guava_27_0_android
        "@android_app//:com_google_guava_guava",
    ]
)
```

### Detailed dependency information specifications

Although you can always give a dependency as a Maven coordinate string,
occasionally special handling is required in the form of additional directives
to properly situate the artifact in the dependency tree. For example, a given
artifact may need to have one of its dependencies excluded to prevent a
conflict.

This situation is provided for by allowing the artifact to be specified as a map
containing all of the required information. This map can express more
information than the coordinate strings can, so internally the coordinate
strings are parsed into the artifact map with default values for the additional
items. To assist in generating the maps, you can pull in the file `specs.bzl`
alongside `defs.bzl` and import the `maven` struct, which provides several
helper functions to assist in creating these maps. An example:

```python
load("@rules_jvm_external//:defs.bzl", "artifact")
load("@rules_jvm_external//:specs.bzl", "maven")

maven_install(
    artifacts = [
        maven.artifact(
            group = "com.google.guava",
            artifact = "guava",
            version = "27.0-android",
            exclusions = [
                ...
            ]
        ),
        "junit:junit:4.12",
        ...
    ],
    repositories = [
        maven.repository(
            "https://some.private.maven.re/po",
            user = "johndoe",
            password = "example-password"
        ),
        "https://repo1.maven.org/maven2",
        ...
    ],
)
```

### Artifact exclusion

If you want to exclude an artifact from the transitive closure of a top level
artifact, specify its `group-id:artifact-id` in the `exclusions` attribute of
the `maven.artifact` helper:

```python
load("@rules_jvm_external//:specs.bzl", "maven")

maven_install(
    artifacts = [
        maven.artifact(
            group = "com.google.guava",
            artifact = "guava",
            version = "27.0-jre",
            exclusions = [
                maven.exclusion(
                    group = "org.codehaus.mojo",
                    artifact = "animal-sniffer-annotations"
                ),
                "com.google.j2objc:j2objc-annotations",
            ]
        ),
        # ...
    ],
    repositories = [
        # ...
    ],
)
```

You can specify the exclusion using either the `maven.exclusion` helper or the
`group-id:artifact-id` string directly.

You can also exclude artifacts globally using the `excluded_artifacts`
attribute in `maven_install`:


```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    excluded_artifacts = [
        "com.google.guava:guava",
    ],
)
```

### Compile-only dependencies

If you want to mark certain artifacts as compile-only dependencies, use the
`neverlink` attribute in the `maven.artifact` helper:

```python
load("@rules_jvm_external//:specs.bzl", "maven")

maven_install(
    artifacts = [
        maven.artifact("com.squareup", "javapoet", "1.11.0", neverlink = True),
    ],
    # ...
)
```

This instructs `rules_jvm_external` to mark the generated target for
`com.squareup:javapoet` with the `neverlink = True` attribute, making the
artifact available only for compilation and not at runtime.

### Test-only dependencies

If you want to mark certain artifacts as test-only dependencies, use the
`testonly` attribute in the `maven.artifact` helper:

```python
load("@rules_jvm_external//:specs.bzl", "maven")

maven_install(
    artifacts = [
        maven.artifact("junit", "junit", "4.13", testonly = True),
    ],
    # ...
)
```

This instructs `rules_jvm_external` to mark the generated target for
`junit:Junit` with the `testonly = True` attribute, making the
artifact available only for tests (e.g. `java_test`), or targets specifically
marked as `testonly = True`.

### Resolving user-specified and transitive dependency version conflicts

Use the `version_conflict_policy` attribute to decide how to resolve conflicts
between artifact versions specified in your `maven_install` rule and those
implicitly picked up as transitive dependencies.

The attribute value can be either `default` or `pinned`.

`default`: use [Coursier's default algorithm](https://get-coursier.io/docs/other-version-handling)
for version handling.

`pinned`: pin the versions of the artifacts that are explicitly specified in `maven_install`.

For example, pulling in guava transitively via google-cloud-storage resolves to
guava-26.0-android.

```python
maven_install(
    name = "pinning",
    artifacts = [
        "com.google.cloud:google-cloud-storage:1.66.0",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ]
)
```

```
$ bazel query @pinning//:all | grep guava_guava
@pinning//:com_google_guava_guava
@pinning//:com_google_guava_guava_26_0_android
```

Pulling in guava-27.0-android directly works as expected.

```python
maven_install(
    name = "pinning",
    artifacts = [
        "com.google.cloud:google-cloud-storage:1.66.0",
        "com.google.guava:guava:27.0-android",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ]
)
```

```
$ bazel query @pinning//:all | grep guava_guava
@pinning//:com_google_guava_guava
@pinning//:com_google_guava_guava_27_0_android
```

Pulling in guava-25.0-android (a lower version), resolves to guava-26.0-android. This is the default version conflict policy in action, where artifacts are resolved to the highest version.

```python
maven_install(
    name = "pinning",
    artifacts = [
        "com.google.cloud:google-cloud-storage:1.66.0",
        "com.google.guava:guava:25.0-android",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ]
)
```

```
$ bazel query @pinning//:all | grep guava_guava
@pinning//:com_google_guava_guava
@pinning//:com_google_guava_guava_26_0_android
```

Now, if we add `version_conflict_policy = "pinned"`, we should see guava-25.0-android getting pulled instead. The rest of non-specified artifacts still resolve to the highest version in the case of version conflicts.

```python
maven_install(
    name = "pinning",
    artifacts = [
        "com.google.cloud:google-cloud-storage:1.66.0",
        "com.google.guava:guava:25.0-android",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ]
    version_conflict_policy = "pinned",
)
```

```
$ bazel query @pinning//:all | grep guava_guava
@pinning//:com_google_guava_guava
@pinning//:com_google_guava_guava_25_0_android
```

### Overriding generated targets

You can override the generated targets for artifacts with a target label of your
choice. For instance, if you want to provide your own definition of
`@maven//:com_google_guava_guava` at `//third_party/guava:guava`, specify the
mapping in the `override_targets` attribute:

```python
maven_install(
    name = "pinning",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
    override_targets = {
        "com.google.guava:guava": "@//third_party/guava:guava",
    },
)
```

Note that the target label contains `@//`, which tells Bazel to reference the
target relative to your main workspace, instead of the `@maven` workspace.

### Proxies

As with other Bazel repository rules, the standard `http_proxy`, `https_proxy`
and `no_proxy` environment variables (and their uppercase counterparts) are
supported.

### Repository aliases

Maven artifact rules like `maven_jar` and `jvm_import_external` generate targets
labels in the form of `@group_artifact//jar`, like `@com_google_guava_guava//jar`. This
is different from the `@maven//:group_artifact` naming style used in this project.

As some Bazel projects depend on the `@group_artifact//jar` style labels, we
provide a `generate_compat_repositories` attribute in `maven_install`. If
enabled, JAR artifacts can also be referenced using the `@group_artifact//jar`
target label. For example, `@maven//:com_google_guava_guava` can also be
referenced using `@com_google_guava_guava//jar`.

The artifacts can also be referenced using the style used by
`java_import_external` as `@group_artifact//:group_artifact` or
`@group_artifact` for short.

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    generate_compat_repositories = True
)

load("@maven//:compat.bzl", "compat_repositories")
compat_repositories()
```

#### Repository remapping

If the `maven_jar` or `jvm_import_external` is not named according to `rules_jvm_external`'s
conventions, you can apply
[repository remapping](https://docs.bazel.build/versions/master/external.html#shadowing-dependencies)
from the expected name to the new name for compatibility.

For example, if an external dependency uses `@guava//jar`, and `rules_jvm_external`
generates `@com_google_guava_guava//jar`, apply the `repo_mapping` attribute to the external
repository WORKSPACE rule, like `http_archive` in this example:

```python
http_archive(
    name = "my_dep",
    repo_mapping = {
        "@guava": "@com_google_guava_guava",
    }
    # ...
)
```

With `repo_mapping`, all references to `@guava//jar` in `@my_dep`'s BUILD files will be mapped
to `@com_google_guava_guava//jar` instead.

### Hiding transitive dependencies

As a convenience, transitive dependencies are visible to your build rules.
However, this can lead to surprises when updating `maven_install`'s `artifacts`
list, since doing so may eliminate transitive dependencies from the build
graph.  To force rule authors to explicitly declare all directly referenced
artifacts, use the `strict_visibility` attribute in `maven_install`:

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    strict_visibility = True
)
```

### Fetch and resolve timeout

The default timeout to fetch and resolve artifacts is 600 seconds.  If you need
to change this to resolve a large number of artifacts you can set the
`resolve_timeout` attribute in `maven_install`:

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    resolve_timeout = 900
)
```

### Jetifier

As part of the [Android
Jetpack](https://medium.com/google-developer-experts/converting-your-android-app-to-jetpack-85aecfce34d3)
migration, convert legacy Android support library (`com.android.support`)
libraries to rely on new AndroidX packages using the
[Jetifier](https://developer.android.com/studio/command-line/jetifier) tool.
Enable jetification by specifying `jetify = True` in `maven_install.`
Control which artifacts to jetify with `jetify_include_list` — list of artifacts that need to be jetified in `groupId:artifactId` format.
By default all artifacts are jetified if `jetify` is set to True.

NOTE: There is a performance penalty to using jetifier due to modifying fetched binaries, fetching
additional `AndroidX` artifacts, and modifying the maven dependency graph.

```python
maven_install(
    artifacts = [
        # ...
    ],
    repositories = [
        # ...
    ],
    jetify = True,
    # Optional
    jetify_include_list = [
        "exampleGroupId:exampleArtifactId",
    ],
)
```

### Provide JVM options for Coursier with `COURSIER_OPTS`

You can set up `COURSIER_OPTS` environment variable to provide some additional JVM options for Coursier.
This is a space-separated list of options.

Assume you'd like to override Coursier's memory settings:

```bash
COURSIER_OPTS="-Xms1g -Xmx4g"
```

## Exporting and consuming artifacts from external repositories

If you're writing a library that has dependencies, you should define a constant that
lists all of the artifacts that your library requires. For example:

```python
# my_library/BUILD
# Public interface of the library
java_library(
  name = "my_interface",
  deps = [
    "@maven//:junit_junit",
    "@maven//:com_google_inject_guice",
  ],
)
```

```python
# my_library/library_deps.bzl
# All artifacts required by the library
MY_LIBRARY_ARTIFACTS = [
  "junit:junit:4.12",
  "com.google.inject:guice:4.0",
]
```

Users of your library can then load the constant in their `WORKSPACE` and add the
artifacts to their `maven_install`. For example:

```python
# user_project/WORKSPACE
load("@my_library//:library_deps.bzl", "MY_LIBRARY_ARTIFACTS")

maven_install(
  artifacts = [
        "junit:junit:4.11",
        "com.google.guava:guava:26.0-jre",
  ] + MY_LIBRARY_ARTIFACTS,
)
```

```python
# user_project/BUILD
java_library(
  name = "user_lib",
  deps = [
    "@my_library//:my_interface",
    "@maven//:junit_junit",
  ],
)
```

Any version conflicts or duplicate artifacts will resolved automatically.

## Publishing to External Repositories

In order to publish an artifact from your repo to a maven repository, you
must first create a `java_export` target. This is similar to a regular
`java_library`, but allows two additional parameters: the maven coordinates
and an optional template file to use for the `pom.xml` file.

```python
# user_project/BUILD
load("@rules_jvm_external//:defs.bzl", "java_export")

java_export(
  name = "exported_lib",
  maven_coordinates = "com.example:project:0.0.1",
  pom_template = "pom.tmpl",  # You can omit this
  srcs = glob(["*.java"]),
  deps = [
    "//user_project/utils",
    "@maven//:com_google_guava_guava",
  ],
)
```  

In order to publish the artifact, use `bazel run`:

`bazel run --define "maven_repo=file://$HOME/.m2/repository" //user_project:exported_lib.publish`

Or, to publish to (eg) Sonatype's OSS repo:

```python
bazel run --stamp \
  --define "maven_repo=https://oss.sonatype.org/service/local/staging/deploy/maven2" \
  --define "maven_user=example_user" \
  --define "maven_password=hunter2" \
  --define gpg_sign=true \
  //user_project:exported_lib.publish`
```

It's also possible to publish to a Google Cloud Storage bucket:

`bazel run --define "maven_repo=gs://example-bucket/repository" //user_project:exported_lib.publish`

When using the `gpg_sign` option, the current default key will be used for
signing, and the `gpg` binary needs to be installed on the machine.

## Demo

You can find demos in the [`examples/`](./examples/) directory.

## Projects using rules_jvm_external

Find other GitHub projects using `rules_jvm_external`
[with this search query](https://github.com/search?p=1&q=rules_jvm_external+filename%3A%2FWORKSPACE+filename%3A%5C.bzl&type=Code).

## Developing this project

### Verbose / debug mode

Set the `RJE_VERBOSE` environment variable to `true` to print `coursier`'s verbose
output. For example:

```
$ RJE_VERBOSE=true bazel run @unpinned_maven//:pin
```

### Tests

```
$ bazel test //...
```

### Generating documentation

Use [Stardoc](https://skydoc.bazel.build/docs/getting_started_stardoc.html) to
generate API documentation in the [docs](docs/) directory using
[generate_docs.sh](scripts/generate_docs.sh).

Note that this script has a dependency on the `doctoc` NPM package to automate
generating the table of contents. Install it with `npm -g i doctoc`.
