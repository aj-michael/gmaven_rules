# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and

load("//third_party/bazel_json/lib:json_parser.bzl", "json_parse")
load("//:specs.bzl", "utils")
load(
    "//:private/versions.bzl",
    "COURSIER_CLI_MAVEN_PATH",
    "COURSIER_CLI_SHA256",
)
load(
    "//:private/special_artifacts.bzl",
    "POM_ONLY_ARTIFACTS",
)

_BUILD = """
package(default_visibility = ["//visibility:public"])

exports_files(["pin"])

load("@{repository_name}//:jvm_import.bzl", "jvm_import")

{imports}
"""

# Coursier uses these types to determine what files it should resolve and fetch.
# For example, some jars have the type "eclipse-plugin", and Coursier would not
# download them if it's not asked to to resolve "eclipse-plugin".
_COURSIER_PACKAGING_TYPES = [
    "jar",
    "aar",
    "bundle",
    "eclipse-plugin",
    "orbit",
    "test-jar",
]

def _strip_packaging_and_classifier(coord):
    # We add "pom" into _COURSIER_PACKAGING_TYPES here because "pom" is not a
    # packaging type that Coursier CLI accepts.
    for packaging_type in _COURSIER_PACKAGING_TYPES + ["pom"]:
        coord = coord.replace(":%s:" % packaging_type, ":")
    for classifier_type in ["sources", "natives"]:
        coord = coord.replace(":%s:" % classifier_type, ":")

    return coord

def _strip_packaging_and_classifier_and_version(coord):
    return ":".join(_strip_packaging_and_classifier(coord).split(":")[:-1])

def _escape(string):
    for char in [".", "-", ":", "/", "+"]:
        string = string.replace(char, "_")
    return string.replace("[", "").replace("]", "").split(",")[0]

def _is_windows(repository_ctx):
    return repository_ctx.os.name.find("windows") != -1

def _is_linux(repository_ctx):
    return repository_ctx.os.name.find("linux") != -1

def _is_macos(repository_ctx):
    return repository_ctx.os.name.find("mac") != -1

# The representation of a Windows path when read from the parsed Coursier JSON
# is delimited by 4 back slashes. Replace them with 1 forward slash.
def _normalize_to_unix_path(path):
    return path.replace("\\\\", "/")

# Relativize an absolute path to an artifact in coursier's default cache location.
# After relativizing, also symlink the path into the workspace's output base.
# Then return the relative path for further processing
def _relativize_and_symlink_file(repository_ctx, absolute_path):
    # The path manipulation from here on out assumes *nix paths, not Windows.
    # for artifact_absolute_path in artifact_absolute_paths:
    #
    # Also replace '\' with '/` to normalize windows paths to *nix style paths
    # BUILD files accept only *nix paths, so we normalize them here.
    #
    # We assume that coursier uses the default cache location
    # TODO(jin): allow custom cache locations
    absolute_path_parts = absolute_path.split("v1/")
    if len(absolute_path_parts) != 2:
        fail("Error while trying to parse the path of file in the coursier cache: " + absolute_path)
    else:
        # Make a symlink from the absolute path of the artifact to the relative
        # path within the output_base/external.
        artifact_relative_path = "v1/" + absolute_path_parts[1]
        repository_ctx.symlink(absolute_path, repository_ctx.path(artifact_relative_path))
    return artifact_relative_path

# Get the reverse dependencies of an artifact from the Coursier parsed
# dependency tree.
def _get_reverse_deps(coord, dep_tree):
    reverse_deps = []

    # For all potential reverse dep artifacts,
    for maybe_rdep in dep_tree["dependencies"]:
        # For all dependencies of this artifact,
        for maybe_rdep_coord in maybe_rdep["dependencies"]:
            # If this artifact depends on the missing artifact,
            if maybe_rdep_coord == coord:
                # Then this artifact is an rdep :-)
                reverse_deps.append(maybe_rdep)
    return reverse_deps

def _genrule_copy_artifact_from_http_file(artifact):
    http_file_repository = _escape(artifact["coord"])
    return "\n".join([
        "genrule(",
        "     name = \"%s_extension\"," % http_file_repository,
        "     srcs = [\"@%s//file\"]," % http_file_repository,
        "     outs = [\"%s\"]," % artifact["file"],
        "     cmd = \"cp $< $@\",",
        ")",
    ])

# Generate BUILD file with java_import and aar_import for each artifact in
# the transitive closure, with their respective deps mapped to the resolved
# tree.
#
# Made function public for testing.
def _generate_imports(repository_ctx, dep_tree, neverlink_artifacts = {}):
    # The list of java_import/aar_import declaration strings to be joined at the end
    all_imports = []

    # A dictionary (set) of coordinates. This is to ensure we don't generate
    # duplicate labels
    #
    # seen_imports :: string -> bool
    seen_imports = {}

    # A list of versionless target labels for jar artifacts. This is used for
    # generating a compatibility layer for repositories. For example, if we generate
    # @maven//:junit_junit, we also generate @junit_junit//jar as an alias to it.
    jar_versionless_target_labels = []

    # First collect a map of target_label to their srcjar relative paths, and symlink the srcjars if needed.
    # We will use this map later while generating target declaration strings with the "srcjar" attr.
    srcjar_paths = None
    if repository_ctx.attr.fetch_sources:
        srcjar_paths = {}
        for artifact in dep_tree["dependencies"]:
            if ":sources:" in artifact["coord"]:
                artifact_path = artifact["file"]
                if artifact_path != None and artifact_path not in seen_imports:
                    seen_imports[artifact_path] = True
                    target_label = _escape(_strip_packaging_and_classifier_and_version(artifact["coord"]))
                    srcjar_paths[target_label] = artifact_path
                    if repository_ctx.attr.maven_install_json:
                        all_imports.append(_genrule_copy_artifact_from_http_file(artifact))

    # Iterate through the list of artifacts, and generate the target declaration strings.
    for artifact in dep_tree["dependencies"]:
        artifact_path = artifact["file"]
        target_label = _escape(_strip_packaging_and_classifier_and_version(artifact["coord"]))

        if target_label in seen_imports:
            # Skip if we've seen this target label before. Every versioned artifact is uniquely mapped to a target label.
            pass
        elif repository_ctx.attr.fetch_sources and ":sources:" in artifact["coord"]:
            # We already processed the sources above, so skip them here.
            pass
        elif target_label not in seen_imports and artifact_path != None:
            seen_imports[target_label] = True

            # 1. Generate the rule class.
            #
            # java_import(
            #
            packaging = artifact_path.split(".").pop()
            if packaging == "jar":
                # Regular `java_import` invokes ijar on all JARs, causing some Scala and
                # Kotlin compile interface JARs to be incorrect. We replace java_import
                # with a simple jvm_import Starlark rule that skips ijar.
                target_import_string = ["jvm_import("]
                jar_versionless_target_labels.append(target_label)
            elif packaging == "aar":
                target_import_string = ["aar_import("]
            else:
                fail("Unsupported packaging type: " + packaging)

            # 2. Generate the target label.
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            #
            target_import_string.append("\tname = \"%s\"," % target_label)

            # 3. Generate the jars/aar attribute to the relative path of the artifact.
            #    Optionally generate srcjar attr too.
            #
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            # 	jars = ["https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            # 	srcjar = "https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3-sources.jar",
            #
            if packaging == "jar":
                target_import_string.append("\tjars = [\"%s\"]," % artifact_path)
                if srcjar_paths != None and target_label in srcjar_paths:
                    target_import_string.append("\tsrcjar = \"%s\"," % srcjar_paths[target_label])
            elif packaging == "aar":
                target_import_string.append("\taar = \"%s\"," % artifact_path)

            # 4. Generate the deps attribute with references to other target labels.
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            # 	jars = ["https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            # 	srcjar = "https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3-sources.jar",
            # 	deps = [
            # 		":org_hamcrest_hamcrest_core",
            # 	],
            #
            target_import_string.append("\tdeps = [")

            # Dedupe dependencies here. Sometimes coursier will return "x.y:z:aar:version" and "x.y:z:version" in the
            # same list of dependencies.
            target_import_labels = []
            for dep in artifact["dependencies"]:
                dep_target_label = _escape(_strip_packaging_and_classifier_and_version(dep))
                # Coursier returns cyclic dependencies sometimes. Handle it here.
                # See https://github.com/bazelbuild/rules_jvm_external/issues/172
                if dep_target_label != target_label:
                    target_import_labels.append("\t\t\":%s\",\n" % dep_target_label)
            target_import_labels = _deduplicate_list(target_import_labels)

            target_import_string.append("".join(target_import_labels) + "\t],")

            # 5. Add a tag with the original maven coordinates for use generating pom files
            # For use with this rule https://github.com/google/bazel-common/blob/f1115e0f777f08c3cdb115526c4e663005bec69b/tools/maven/pom_file.bzl#L177
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            # 	jars = ["https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            # 	srcjar = "https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3-sources.jar",
            # 	deps = [
            # 		":org_hamcrest_hamcrest_core",
            # 	],
            #   tags = ["maven_coordinates=org.hamcrest:hamcrest.library:1.3"],
            target_import_string.append("\ttags = [\"maven_coordinates=%s\"]," % artifact["coord"])

            # 6. If `neverlink` is True in the artifact spec, add the neverlink attribute to make this artifact
            #    available only as a compile time dependency.
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            # 	jars = ["https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            # 	srcjar = "https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3-sources.jar",
            # 	deps = [
            # 		":org_hamcrest_hamcrest_core",
            # 	],
            #   tags = ["maven_coordinates=org.hamcrest:hamcrest.library:1.3"],
            #   neverlink = True,
            if (neverlink_artifacts.get(_strip_packaging_and_classifier_and_version(artifact["coord"]))):
                target_import_string.append("\tneverlink = True,")

            # 7. Finish the java_import rule.
            #
            # java_import(
            # 	name = "org_hamcrest_hamcrest_library",
            # 	jars = ["https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            # 	srcjar = "https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3-sources.jar",
            # 	deps = [
            # 		":org_hamcrest_hamcrest_core",
            # 	],
            #   tags = ["maven_coordinates=org.hamcrest:hamcrest.library:1.3"],
            #   neverlink = True,
            # )
            target_import_string.append(")")

            all_imports.append("\n".join(target_import_string))

            # 8. Create a versionless alias target
            #
            # alias(
            #   name = "org_hamcrest_hamcrest_library_1_3",
            #   actual = "org_hamcrest_hamcrest_library",
            # )
            versioned_target_alias_label = _escape(_strip_packaging_and_classifier(artifact["coord"]))
            all_imports.append("alias(\n\tname = \"%s\",\n\tactual = \"%s\",\n)" % (versioned_target_alias_label, target_label))

            # 9. If using maven_install.json, use a genrule to copy the file from the http_file
            # repository into this repository.
            #
            # genrule(
            #     name = "org_hamcrest_hamcrest_library_1_3_extension",
            #     srcs = ["@org_hamcrest_hamcrest_library_1_3//file"],
            #     outs = ["@maven//:v1/https/repo1.maven.org/maven2/org/hamcrest/hamcrest-library/1.3/hamcrest-library-1.3.jar"],
            #     cmd = "cp $< $@",
            # )
            if repository_ctx.attr.maven_install_json:
                all_imports.append(_genrule_copy_artifact_from_http_file(artifact))

        elif artifact_path == None and POM_ONLY_ARTIFACTS.get(_strip_packaging_and_classifier_and_version(artifact["coord"])):
            # Special case for certain artifacts that only come with a POM file. Such artifacts "aggregate" their dependencies,
            # so they don't have a JAR for download.
            seen_imports[target_label] = True
            target_import_string = ["java_library("]
            target_import_string.append("\tname = \"%s\"," % target_label)
            target_import_string.append("\texports = [")

            target_import_labels = []
            for dep in artifact["dependencies"]:
                dep_target_label = _escape(_strip_packaging_and_classifier_and_version(dep))
                # Coursier returns cyclic dependencies sometimes. Handle it here.
                # See https://github.com/bazelbuild/rules_jvm_external/issues/172
                if dep_target_label != target_label:
                    target_import_labels.append("\t\t\":%s\",\n" % dep_target_label)
            target_import_labels = _deduplicate_list(target_import_labels)

            target_import_string.append("".join(target_import_labels) + "\t],")
            target_import_string.append("\ttags = [\"maven_coordinates=%s\"]," % artifact["coord"])
            target_import_string.append(")")

            all_imports.append("\n".join(target_import_string))

            versioned_target_alias_label = _escape(_strip_packaging_and_classifier(artifact["coord"]))
            all_imports.append("alias(\n\tname = \"%s\",\n\tactual = \"%s\",\n)" % (versioned_target_alias_label, target_label))

        elif artifact_path == None:
            # Possible reasons that the artifact_path is None:
            #
            # https://github.com/bazelbuild/rules_jvm_external/issues/70
            # https://github.com/bazelbuild/rules_jvm_external/issues/74

            # Get the reverse deps of the missing artifact.
            reverse_deps = _get_reverse_deps(artifact["coord"], dep_tree)
            reverse_dep_coords = [reverse_dep["coord"] for reverse_dep in reverse_deps]
            reverse_dep_pom_paths = [
                repository_ctx.path(reverse_dep["file"].replace(".jar", ".pom").replace(".aar", ".pom"))
                for reverse_dep in reverse_deps
            ]

            rdeps_message = """
It is also possible that the packaging type of {artifact} is specified
incorrectly in the POM file of an artifact that depends on it. For example,
{artifact} may be an AAR, but the dependent's POM file specified its `<type>`
value to be a JAR.

The artifact(s) depending on {artifact} are:

{reverse_dep_coords}

and their POM files are located at:

{reverse_dep_pom_paths}""".format(
                artifact = artifact["coord"],
                reverse_dep_coords = "\n".join(reverse_dep_coords),
                reverse_dep_pom_paths = "\n".join(reverse_dep_pom_paths),
                parsed_artifact = repr(artifact),
            )

            error_message = """
The artifact for {artifact} was not downloaded. Perhaps its packaging type is
not one of: {packaging_types}?

Parsed artifact data: {parsed_artifact}

{rdeps_message}""".format(
                artifact = artifact["coord"],
                packaging_types = ",".join(_COURSIER_PACKAGING_TYPES),
                parsed_artifact = repr(artifact),
                rdeps_message = rdeps_message if len(reverse_dep_coords) > 0 else "",
            )

            fail(error_message)
        else:
            error_message = """Unable to generate a target for this artifact.

Please file an issue on https://github.com/bazelbuild/rules_jvm_external/issues/new
and include the following snippet:

Artifact coordinates: {artifact}
Parsed data: {parsed_artifact}""".format(
                artifact = artifact["coord"],
                parsed_artifact = repr(artifact),
            )
            fail(error_message)

    return ("\n".join(all_imports), jar_versionless_target_labels)

def _deduplicate_list(items):
    seen_items = {}
    unique_items = []
    for item in items:
        if item not in seen_items:
            seen_items[item] = True
            unique_items.append(item)
    return unique_items

# Generate the base `coursier` command depending on the OS, JAVA_HOME or the
# location of `java`.
def _generate_coursier_command(repository_ctx):
    coursier = repository_ctx.path("coursier")
    java_home = repository_ctx.os.environ.get("JAVA_HOME")

    if java_home != None:
        # https://github.com/coursier/coursier/blob/master/doc/FORMER-README.md#how-can-the-launcher-be-run-on-windows-or-manually-with-the-java-program
        # The -noverify option seems to be required after the proguarding step
        # of the main JAR of coursier.
        java = repository_ctx.path(java_home + "/bin/java")
        cmd = [java, "-noverify", "-jar"] + _get_java_proxy_args(repository_ctx) + [coursier]
    elif repository_ctx.which("java") != None:
        # Use 'java' from $PATH
        cmd = [repository_ctx.which("java"), "-noverify", "-jar"] + _get_java_proxy_args(repository_ctx) + [coursier]
    else:
        # Try to execute coursier directly
        cmd = [coursier] + ["-J%s" % arg for arg in _get_java_proxy_args(repository_ctx)]

    return cmd

# Extract the well-known environment variables http_proxy, https_proxy and
# no_proxy and convert them to java.net-compatible property arguments.
def _get_java_proxy_args(repository_ctx):
    # Check both lower- and upper-case versions of the environment variables, preferring the former
    http_proxy = repository_ctx.os.environ.get("http_proxy", repository_ctx.os.environ.get("HTTP_PROXY"))
    https_proxy = repository_ctx.os.environ.get("https_proxy", repository_ctx.os.environ.get("HTTPS_PROXY"))
    no_proxy = repository_ctx.os.environ.get("no_proxy", repository_ctx.os.environ.get("NO_PROXY"))

    proxy_args = []

    # Extract the host and port from a standard proxy URL:
    # http://proxy.example.com:3128 -> ["proxy.example.com", "3128"]
    if http_proxy:
        proxy = http_proxy.split("://", 1)[1].split(":", 1)
        proxy_args.extend([
            "-Dhttp.proxyHost=%s" % proxy[0],
            "-Dhttp.proxyPort=%s" % proxy[1],
        ])

    if https_proxy:
        proxy = https_proxy.split("://", 1)[1].split(":", 1)
        proxy_args.extend([
            "-Dhttps.proxyHost=%s" % proxy[0],
            "-Dhttps.proxyPort=%s" % proxy[1],
        ])

    # Convert no_proxy-style exclusions, including base domain matching, into java.net nonProxyHosts:
    # localhost,example.com,foo.example.com,.otherexample.com -> "localhost|example.com|foo.example.com|*.otherexample.com"
    if no_proxy != None:
        proxy_args.append("-Dhttp.nonProxyHosts=%s" % no_proxy.replace(",", "|").replace("|.", "|*."))

    return proxy_args

def _windows_check(repository_ctx):
    # TODO(jin): Remove BAZEL_SH usage ASAP. Bazel is going bashless, so BAZEL_SH
    # will not be around for long.
    #
    # On Windows, run msys once to bootstrap it
    # https://github.com/bazelbuild/rules_jvm_external/issues/53
    if (_is_windows(repository_ctx)):
        bash = repository_ctx.os.environ.get("BAZEL_SH")
        if (bash == None):
            fail("Please set the BAZEL_SH environment variable to the path of MSYS2 bash. " +
                 "This is typically `c:\\msys64\\usr\\bin\\bash.exe`. For more information, read " +
                 "https://docs.bazel.build/versions/master/install-windows.html#getting-bazel")

def _pinned_coursier_fetch_impl(repository_ctx):
    if not repository_ctx.attr.maven_install_json:
        fail("Please specify the file label to maven_install.json (e.g."
             + "//:maven_install.json).")

    _windows_check(repository_ctx)

    artifacts = []
    for a in repository_ctx.attr.artifacts:
        artifacts.append(json_parse(a))

    # Read Coursier state from maven_install.json.
    repository_ctx.symlink(
        repository_ctx.path(repository_ctx.attr.maven_install_json),
        repository_ctx.path("imported_maven_install.json")
    )
    maven_install_json_content = json_parse(
        repository_ctx.read(
            repository_ctx.path("imported_maven_install.json")),
        fail_on_invalid = False,
    )
    if maven_install_json_content == None:
        fail("Failed to parse %s. Is this file valid JSON? The file may have been corrupted." % repository_ctx.path(repository_ctx.attr.maven_install_json)
             + "Consider regenerating maven_install.json with the following steps:\n"
             + "  1. Remove the maven_install_json attribute from your `maven_install` declaration for `@%s`.\n" % repository_ctx.name
             + "  2. Regenerate `maven_install.json` by running the command: bazel run @%s//:pin" % repository_ctx.name
             + "  3. Add `maven_install_json = \"//:maven_install.json\"` into your `maven_install` declaration.")

    if maven_install_json_content.get("dependency_tree") == None:
        fail("Failed to parse %s. " % repository_ctx.path(repository_ctx.attr.maven_install_json)
                + "It is not a valid maven_install.json file. Has this "
                + "file been modified manually?")

    dep_tree = maven_install_json_content["dependency_tree"]

    # Create the list of http_file repositories for each of the artifacts
    # in maven_install.json. This will be loaded additionally like so:
    #
    # load("@maven//:defs.bzl", "pinned_maven_install")
    # pinned_maven_install()
    http_files = [
        "load(\"@bazel_tools//tools/build_defs/repo:http.bzl\", \"http_file\")",
        "def pinned_maven_install():",
    ]
    for artifact in dep_tree["dependencies"]:
        if artifact.get("url") != None:
            http_file_repository_name = _escape(artifact["coord"])
            http_files.extend([
                "    http_file(",
                "        name = \"%s\"," % http_file_repository_name,
                "        urls = [\"%s\"]," % artifact["url"],
                "        sha256 = \"%s\"," % artifact["sha256"],
                "    )",
            ])
    repository_ctx.file("defs.bzl", "\n".join(http_files), executable = False)

    repository_ctx.report_progress("Generating BUILD targets..")
    (generated_imports, jar_versionless_target_labels) = _generate_imports(
        repository_ctx = repository_ctx,
        dep_tree = dep_tree,
        neverlink_artifacts = {
            a["group"] + ":" + a["artifact"]: True
            for a in artifacts
            if a.get("neverlink", False)
        },
    )

    repository_ctx.template(
        "jvm_import.bzl",
        repository_ctx.attr._jvm_import,
        substitutions = {},
        executable = False,  # not executable
    )

    repository_ctx.template(
        "compat_repository.bzl",
        repository_ctx.attr._compat_repository,
        substitutions = {},
        executable = False,  # not executable
    )

    repository_ctx.file(
        "BUILD",
        _BUILD.format(
            repository_name = repository_ctx.name,
            imports = generated_imports,
        ),
        False,  # not executable
    )

    # Generate a compatibility layer of external repositories for all jar artifacts.
    if repository_ctx.attr.generate_compat_repositories:
        compat_repositories_bzl = ["load(\"@%s//:compat_repository.bzl\", \"compat_repository\")" % repository_ctx.name]
        compat_repositories_bzl.append("def compat_repositories():")
        for versionless_target_label in jar_versionless_target_labels:
            compat_repositories_bzl.extend([
                "    compat_repository(",
                "        name = \"%s\"," % versionless_target_label,
                "        generating_repository = \"%s\"," % repository_ctx.name,
                "    )",
            ])
            repository_ctx.file(
                "compat.bzl",
                "\n".join(compat_repositories_bzl) + "\n",
                False,  # not executable
            )

def _coursier_fetch_impl(repository_ctx):
    # Not using maven_install.json, so we resolve and fetch from scratch.
    # This takes significantly longer as it doesn't rely on any local
    # caches and uses Coursier's own download mechanisms.

    # Download Coursier's standalone (deploy) jar from Maven repositories.
    repository_ctx.download([
        "https://jcenter.bintray.com/" + COURSIER_CLI_MAVEN_PATH,
        "http://central.maven.org/maven2/" + COURSIER_CLI_MAVEN_PATH,
    ], "coursier", sha256 = COURSIER_CLI_SHA256, executable = True)

    # Try running coursier once
    exec_result = repository_ctx.execute(_generate_coursier_command(repository_ctx))
    if exec_result.return_code != 0:
        fail("Unable to run coursier: " + exec_result.stderr)

    _windows_check(repository_ctx)

    # Deserialize the spec blobs
    repositories = []
    for repository in repository_ctx.attr.repositories:
        repositories.append(json_parse(repository))

    artifacts = []
    for a in repository_ctx.attr.artifacts:
        artifacts.append(json_parse(a))

    excluded_artifacts = []
    for a in repository_ctx.attr.excluded_artifacts:
        excluded_artifacts.append(json_parse(a))

    artifact_coordinates = []

    # Set up artifact exclusion, if any. From coursier fetch --help:
    #
    # Path to the local exclusion file. Syntax: <org:name>--<org:name>. `--` means minus. Example file content:
    # com.twitter.penguin:korean-text--com.twitter:util-tunable-internal_2.11
    # org.apache.commons:commons-math--com.twitter.search:core-query-nodes
    # Behavior: If root module A excludes module X, but root module B requires X, module X will still be fetched.
    exclusion_lines = []
    for a in artifacts:
        artifact_coordinates.append(utils.artifact_coordinate(a))
        if "exclusions" in a:
            for e in a["exclusions"]:
                exclusion_lines.append(":".join([a["group"], a["artifact"]]) +
                                       "--" +
                                       ":".join([e["group"], e["artifact"]]))

    cmd = _generate_coursier_command(repository_ctx)
    cmd.extend(["fetch"])
    cmd.extend(artifact_coordinates)
    if repository_ctx.attr.version_conflict_policy == "pinned":
        for coord in artifact_coordinates:
            # Undo any `,classifier=` suffix from `utils.artifact_coordinate`.
            cmd.extend(["--force-version", coord.split(",classifier=")[0]])
    cmd.extend(["--artifact-type", ",".join(_COURSIER_PACKAGING_TYPES + ["src"])])
    cmd.append("--quiet")
    cmd.append("--no-default")
    cmd.extend(["--json-output-file", "dep-tree.json"])

    if repository_ctx.attr.fail_on_missing_checksum:
        cmd.extend(["--checksum", "SHA-1,MD5"])
    else:
        cmd.extend(["--checksum", "SHA-1,MD5,None"])

    if len(exclusion_lines) > 0:
        repository_ctx.file("exclusion-file.txt", "\n".join(exclusion_lines), False)
        cmd.extend(["--local-exclude-file", "exclusion-file.txt"])
    for repository in repositories:
        cmd.extend(["--repository", utils.repo_url(repository)])
    for a in excluded_artifacts:
        cmd.extend(["--exclude", ":".join([a["group"], a["artifact"]])])
    if not repository_ctx.attr.use_unsafe_shared_cache:
        cmd.extend(["--cache", "v1"])  # Download into $output_base/external/$maven_repo_name/v1
    if repository_ctx.attr.fetch_sources:
        cmd.append("--sources")
        cmd.append("--default=true")
    if _is_windows(repository_ctx):
        # Unfortunately on Windows, coursier crashes while trying to acquire the
        # cache's .structure.lock file while running in parallel. This does not
        # happen on *nix.
        cmd.extend(["--parallel", "1"])

    repository_ctx.report_progress("Resolving and fetching the transitive closure of %s artifact(s).." % len(artifact_coordinates))
    exec_result = repository_ctx.execute(cmd)
    if (exec_result.return_code != 0):
        fail("Error while fetching artifact with coursier: " + exec_result.stderr)

    # Once coursier finishes a fetch, it generates a tree of artifacts and their
    # transitive dependencies in a JSON file. We use that as the source of truth
    # to generate the repository's BUILD file.
    dep_tree = json_parse(repository_ctx.read(repository_ctx.path("dep-tree.json")))

    # Reconstruct the original URLs from the relative path to the artifact,
    # which encodes the URL components for the protocol, domain, and path to
    # the file.
    for artifact in dep_tree["dependencies"]:
        # Some artifacts don't contain files; they are just parent artifacts
        # to other artifacts.
        if artifact["file"] != None:
            # Normalize paths in place here.
            artifact.update({"file": _normalize_to_unix_path(artifact["file"])})

            if repository_ctx.attr.use_unsafe_shared_cache:
                artifact.update({"file": _relativize_and_symlink_file(repository_ctx, artifact["file"])})

            # Coursier saves the artifacts into a subdirectory structure
            # that mirrors the URL where the artifact's fetched from. Using
            # this, we can reconstruct the original URL.
            url = []
            filepath_parts = artifact["file"].split("/")
            protocol = None
            # Only support http/https transports
            for part in filepath_parts:
                if part == "http" or part == "https":
                     protocol = part
            if protocol == None:
                fail("Only artifacts downloaded over http(s) are supported: %s" % artifact["coord"]) 
            url.extend([protocol, "://"])
            for part in filepath_parts[filepath_parts.index(protocol) + 1:]:
                url.extend([part, "/"])
            url.pop() # pop the final "/"

            # Coursier encodes the colon ':' character as "%3A" in the
            # filepath. Convert it back to colon since it's used for ports.
            artifact.update({"url": "".join(url).replace("%3A", ":")})

            # Compute the sha256 of the file.
            exec_result = repository_ctx.execute([
                "python",
                repository_ctx.path(repository_ctx.attr._sha256_tool),
                repository_ctx.path(artifact["file"]),
                "artifact.sha256",
            ])

            if exec_result.return_code != 0:
                fail("Error while obtaining the sha256 checksum of "
                        + artifact["file"] + ": " + exec_result.stderr)

            # Update the SHA-256 checksum in-place.
            artifact.update({"sha256": repository_ctx.read("artifact.sha256")})

    neverlink_artifacts = {a["group"] + ":" + a["artifact"]: True for a in artifacts if a.get("neverlink", False)}
    repository_ctx.report_progress("Generating BUILD targets..")
    (generated_imports, jar_versionless_target_labels) = _generate_imports(
        repository_ctx = repository_ctx,
        dep_tree = dep_tree,
        neverlink_artifacts = neverlink_artifacts,
    )

    repository_ctx.template(
        "jvm_import.bzl",
        repository_ctx.attr._jvm_import,
        substitutions = {},
        executable = False,  # not executable
    )

    repository_ctx.file(
        "BUILD",
        _BUILD.format(
            repository_name = repository_ctx.name,
            imports = generated_imports,
        ),
        False,  # not executable
    )

    # Expose the script to let users pin the state of the fetch in
    # `<workspace_root>/maven_install.json`.
    #
    # $ bazel run @unpinned_maven//:pin
    #
    # Create the maven_install.json export script for unpinned repositories.
    dependency_tree_json = "{ \"dependency_tree\": " + repr(dep_tree).replace("None", "null") + "}"
    repository_ctx.template("pin", repository_ctx.attr._pin,
        {
            "{dependency_tree_json}": dependency_tree_json,
            "{repository_name}": \
                repository_ctx.name[len("unpinned_"):] \
                if repository_ctx.name.startswith("unpinned_") \
                else repository_ctx.name,
        },
        executable = True,
    )

    # Generate a compatibility layer of external repositories for all jar artifacts.
    if repository_ctx.attr.generate_compat_repositories:
        repository_ctx.template(
            "compat_repository.bzl",
            repository_ctx.attr._compat_repository,
            substitutions = {},
            executable = False,  # not executable
        )

        compat_repositories_bzl = ["load(\"@%s//:compat_repository.bzl\", \"compat_repository\")" % repository_ctx.name]
        compat_repositories_bzl.append("def compat_repositories():")
        for versionless_target_label in jar_versionless_target_labels:
            compat_repositories_bzl.extend([
                "    compat_repository(",
                "        name = \"%s\"," % versionless_target_label,
                "        generating_repository = \"%s\"," % repository_ctx.name,
                "    )",
            ])
        repository_ctx.file(
            "compat.bzl",
            "\n".join(compat_repositories_bzl) + "\n",
            False,  # not executable
        )

pinned_coursier_fetch = repository_rule(
    attrs = {
        "_jvm_import": attr.label(default = "//:private/jvm_import.bzl"),
        "_compat_repository": attr.label(default = "//:private/compat_repository.bzl"),
        "artifacts": attr.string_list(),  # list of artifact objects, each as json
        "fetch_sources": attr.bool(default = False),
        "generate_compat_repositories": attr.bool(default = False),  # generate a compatible layer with repositories for each artifact
        "maven_install_json": attr.label(allow_single_file = True),
    },
    implementation = _pinned_coursier_fetch_impl,
)

coursier_fetch = repository_rule(
    attrs = {
        "_sha256_tool": attr.label(default = "@bazel_tools//tools/build_defs/hash:sha256.py"),
        "_jvm_import": attr.label(default = "//:private/jvm_import.bzl"),
        "_pin": attr.label(default = "//:private/pin.sh"),
        "_compat_repository": attr.label(default = "//:private/compat_repository.bzl"),
        "repositories": attr.string_list(),  # list of repository objects, each as json
        "artifacts": attr.string_list(),  # list of artifact objects, each as json
        "fail_on_missing_checksum": attr.bool(default = True),
        "fetch_sources": attr.bool(default = False),
        "use_unsafe_shared_cache": attr.bool(default = False),
        "excluded_artifacts": attr.string_list(default = []),  # list of artifacts to exclude
        "generate_compat_repositories": attr.bool(default = False),  # generate a compatible layer with repositories for each artifact
        "version_conflict_policy": attr.string(
            doc = """Policy for user-defined vs. transitive dependency version conflicts

            If "pinned", choose the user-specified version in maven_install unconditionally.
            If "default", follow Coursier's default policy.
            """,
            default = "default",
            values = ["default", "pinned"],
        ),
        "maven_install_json": attr.label(allow_single_file = True),
    },
    environ = [
        "JAVA_HOME",
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "no_proxy",
        "NO_PROXY",
    ],
    implementation = _coursier_fetch_impl,
)
