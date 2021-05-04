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
load("//private/rules:jetifier.bzl", "jetify_artifact_dependencies", "jetify_maven_coord")
load("//:specs.bzl", "maven", "parse", "utils")
load("//:private/proxy.bzl", "get_java_proxy_args")
load("//:private/dependency_tree_parser.bzl", "JETIFY_INCLUDE_LIST_JETIFY_ALL", "parser")
load("//:private/coursier_utilities.bzl", "SUPPORTED_PACKAGING_TYPES", "escape")
load(
    "//:private/versions.bzl",
    "COURSIER_CLI_BAZEL_MIRROR_URL",
    "COURSIER_CLI_GITHUB_ASSET_URL",
    "COURSIER_CLI_SHA256",
    "JQ_VERSIONS",
)

_BUILD = """
package(default_visibility = ["//visibility:{visibility}"])

load("@rules_jvm_external//private/rules:jvm_import.bzl", "jvm_import")
load("@rules_jvm_external//private/rules:jetifier.bzl", "jetify_aar_import", "jetify_jvm_import")
{aar_import_statement}

{imports}
"""

DEFAULT_AAR_IMPORT_LABEL = "@build_bazel_rules_android//android:rules.bzl"

_AAR_IMPORT_STATEMENT = """\
load("%s", "aar_import")
"""


_BUILD_PIN = """
genrule(
    name = "jq-binary",
    cmd = "cp $< $@",
    outs = ["jq"],
    srcs = select({{
        "@bazel_tools//src/conditions:linux_x86_64": ["jq-linux"],
        "@bazel_tools//src/conditions:darwin": ["jq-macos"],
        "@bazel_tools//src/conditions:windows": ["jq-windows"],
    }}),
)

sh_binary(
    name = "pin",
    srcs = ["pin.sh"],
    args = [
      "$(rootpath :jq-binary)",
    ],
    data = [
        ":jq-binary",
    ],
    visibility = ["//visibility:public"],
)
"""

_BUILD_OUTDATED = """
sh_binary(
    name = "outdated",
    srcs = ["outdated.sh"],
    data = [
        "@rules_jvm_external//private/tools/prebuilt:outdated_deploy.jar",
        "outdated.artifacts",
        "outdated.repositories"
    ],
)
"""

def _is_verbose(repository_ctx):
    return bool(repository_ctx.os.environ.get("RJE_VERBOSE"))

def _is_windows(repository_ctx):
    return repository_ctx.os.name.find("windows") != -1

def _is_linux(repository_ctx):
    return repository_ctx.os.name.find("linux") != -1

def _is_macos(repository_ctx):
    return repository_ctx.os.name.find("mac") != -1

def _is_file(repository_ctx, path):
    return repository_ctx.which("test") and repository_ctx.execute(["test", "-f", path]).return_code == 0

def _is_directory(repository_ctx, path):
    return repository_ctx.which("test") and repository_ctx.execute(["test", "-d", path]).return_code == 0

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
    absolute_path_parts = absolute_path.split(get_coursier_cache_or_default(
        repository_ctx,
        repository_ctx.attr.use_unsafe_shared_cache or repository_ctx.attr.name.startswith("unpinned_"),
    ))
    if len(absolute_path_parts) != 2:
        fail("Error while trying to parse the path of file in the coursier cache: " + absolute_path)
    else:
        # Make a symlink from the absolute path of the artifact to the relative
        # path within the output_base/external.
        artifact_relative_path = "v1" + absolute_path_parts[1]
        repository_ctx.symlink(absolute_path, repository_ctx.path(artifact_relative_path))
    return artifact_relative_path

def _get_aar_import_statement_or_empty_str(repository_ctx):
  if repository_ctx.attr.use_starlark_android_rules:
    # parse the label to validate it
    _ = Label(repository_ctx.attr.aar_import_bzl_label)
    return _AAR_IMPORT_STATEMENT % repository_ctx.attr.aar_import_bzl_label
  else:
    return ""

# Generate the base `coursier` command depending on the OS, JAVA_HOME or the
# location of `java`.
def _generate_java_jar_command(repository_ctx, jar_path):
    java_home = repository_ctx.os.environ.get("JAVA_HOME")
    coursier_opts = repository_ctx.os.environ.get("COURSIER_OPTS", "")
    coursier_opts = coursier_opts.split(" ") if len(coursier_opts) > 0 else []

    if repository_ctx.attr.java_binary != None:
        java = repository_ctx.path(repository_ctx.attr.java_binary)
        cmd = [java, "-noverify", "-jar"] + coursier_opts + _get_java_proxy_args(repository_ctx) + [jar_path]
    elif java_home != None:
        # https://github.com/coursier/coursier/blob/master/doc/FORMER-README.md#how-can-the-launcher-be-run-on-windows-or-manually-with-the-java-program
        # The -noverify option seems to be required after the proguarding step
        # of the main JAR of coursier.
        java = repository_ctx.path(java_home + "/bin/java")
        cmd = [java, "-noverify", "-jar"] + coursier_opts + _get_java_proxy_args(repository_ctx) + [jar_path]
    elif repository_ctx.which("java") != None:
        # Use 'java' from $PATH
        cmd = [repository_ctx.which("java"), "-noverify", "-jar"] + coursier_opts + _get_java_proxy_args(repository_ctx) + [jar_path]
    else:
        # Try to execute coursier directly
        cmd = [jar_path] + coursier_opts + ["-J%s" % arg for arg in _get_java_proxy_args(repository_ctx)]

    return cmd

# Extract the well-known environment variables http_proxy, https_proxy and
# no_proxy and convert them to java.net-compatible property arguments.
def _get_java_proxy_args(repository_ctx):
    # Check both lower- and upper-case versions of the environment variables, preferring the former
    http_proxy = repository_ctx.os.environ.get("http_proxy", repository_ctx.os.environ.get("HTTP_PROXY"))
    https_proxy = repository_ctx.os.environ.get("https_proxy", repository_ctx.os.environ.get("HTTPS_PROXY"))
    no_proxy = repository_ctx.os.environ.get("no_proxy", repository_ctx.os.environ.get("NO_PROXY"))
    return get_java_proxy_args(http_proxy, https_proxy, no_proxy)

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

# Deterministically compute a signature of a list of artifacts in the dependency tree.
# This is to prevent users from manually editing maven_install.json.
def _compute_dependency_tree_signature(artifacts):
    # A collection of elements from the dependency tree to be sorted and hashed
    # into a signature for maven_install.json.
    signature_inputs = []
    for artifact in artifacts:
        artifact_group = []
        artifact_group.append(artifact["coord"])
        if artifact["file"] != None:
            artifact_group.extend([
                artifact["sha256"],
                artifact["file"],
                artifact["url"],
            ])
        if len(artifact["dependencies"]) > 0:
            artifact_group.append(",".join(sorted(artifact["dependencies"])))
        signature_inputs.append(":".join(artifact_group))
    return hash(repr(sorted(signature_inputs)))

# Compute a signature of the list of artifacts that will be used to build
# the dependency tree. This is used as a check to see whether the dependency
# tree needs to be repinned.
#
# Visible for testing
def compute_dependency_inputs_signature(artifacts):
    artifact_inputs = []
    for artifact in artifacts:
        parsed = json_parse(artifact)

        # Sort the keys to provide a stable order
        keys = sorted(parsed.keys())
        flattened = ":".join(["%s=%s" % (key, parsed[key]) for key in keys])
        artifact_inputs.append(flattened)
    return hash(repr(sorted(artifact_inputs)))

def extract_netrc_from_auth_url(url):
    """Return a dict showing the netrc machine, login, and password extracted from a url.

    Returns:
        A dict that is empty if there were no credentials in the url.
        A dict that has three keys -- machine, login, password -- with their respective values. These values should be
        what is needed for the netrc entry of the same name except for password whose value may be empty meaning that
        there is no password for that login.
    """
    if "@" not in url:
        return {}
    protocol, url_parts = split_url(url)
    login_password_host = url_parts[0]
    if "@" not in login_password_host:
        return {}
    login_password, host = login_password_host.rsplit("@", 1)
    login_password_split = login_password.split(":", 1)
    login = login_password_split[0]

    # If password is not provided, then this will be a 1-length split
    if len(login_password_split) < 2:
        password = None
    else:
        password = login_password_split[1]
    if not host:
        fail("Got a blank host from: {}".format(url))
    if not login:
        fail("Got a blank login from: {}".format(url))

    # Do not fail for blank password since that is sometimes a thing
    return {
        "machine": host,
        "login": login,
        "password": password,
    }

def add_netrc_entries_from_mirror_urls(netrc_entries, mirror_urls):
    """Add a url's auth credentials into a netrc dict of form return[machine][login] = password."""
    for url in mirror_urls:
        entry = extract_netrc_from_auth_url(url)
        if not entry:
            continue
        machine = entry["machine"]
        login = entry["login"]
        password = entry["password"]
        if machine not in netrc_entries:
            netrc_entries[machine] = {}
        if login not in netrc_entries[machine]:
            if netrc_entries[machine]:
                print("Received multiple logins for machine '{}'! Only using '{}'".format(
                    machine,
                    netrc_entries[machine].keys()[0],
                ))
                continue
            netrc_entries[machine][login] = password
        elif netrc_entries[machine][login] != password:
            print("Received different passwords for {}@{}! Only using the first".format(login, machine))
    return netrc_entries

def get_netrc_lines_from_entries(netrc_entries):
    netrc_lines = []
    for machine, login_dict in sorted(netrc_entries.items()):
        for login, password in sorted(login_dict.items()):
            netrc_lines.append("machine {}".format(machine))
            netrc_lines.append("login {}".format(login))
            if password:
                netrc_lines.append("password {}".format(password))
    return netrc_lines

def get_home_netrc_contents(repository_ctx):
    # Copied with a ctx -> repository_ctx rename from tools/build_defs/repo/http.bzl's _get_auth.
    # Need to keep updated with improvements in source since we cannot load private methods.
    if "HOME" in repository_ctx.os.environ:
        if not repository_ctx.os.name.startswith("windows"):
            netrcfile = "%s/.netrc" % (repository_ctx.os.environ["HOME"],)
            if _is_file(repository_ctx, netrcfile):
                return repository_ctx.read(netrcfile)
    return ""

def _get_jq_http_files():
    """Returns repository targets for the `jq` dependency that `pin.sh` needs."""
    lines = []
    for jq in JQ_VERSIONS:
        lines.extend([
            "    maybe(",
            "        http_file,",
            "        name = \"rules_jvm_external_jq_%s\"," % jq,
            "        urls = %s," % repr([JQ_VERSIONS[jq].url]),
            "        sha256 = %s," % repr(JQ_VERSIONS[jq].sha256),
            "        downloaded_file_path = \"jq\",",
            "        executable = True,",
            "    )",
        ])
    return lines

def _add_outdated_files(repository_ctx, artifacts, repositories):
    repository_ctx.file(
        "outdated.artifacts",
        "\n".join(["{}:{}:{}".format(artifact["group"], artifact["artifact"], artifact["version"]) for artifact in artifacts]) + "\n",
        executable = False,
    )

    repository_ctx.file(
        "outdated.repositories",
        "\n".join([repo["repo_url"] for repo in repositories]) + "\n",
        executable = False,
    )

    repository_ctx.template(
        "outdated.sh",
        repository_ctx.attr._outdated,
        {
            "{repository_name}": repository_ctx.name,
            "{proxy_opts}": " ".join(_get_java_proxy_args(repository_ctx)),
        },
        executable = True,
    )

def _fail_if_repin_required(repository_ctx):
    if not repository_ctx.attr.fail_if_repin_required:
        return False

    return "REPIN" not in repository_ctx.os.environ.keys()

def _pinned_coursier_fetch_impl(repository_ctx):
    if not repository_ctx.attr.maven_install_json:
        fail("Please specify the file label to maven_install.json (e.g." +
             "//:maven_install.json).")

    _windows_check(repository_ctx)

    repositories = []
    for repository in repository_ctx.attr.repositories:
        repositories.append(json_parse(repository))

    artifacts = []
    for artifact in repository_ctx.attr.artifacts:
        artifacts.append(json_parse(artifact))

    # Read Coursier state from maven_install.json.
    repository_ctx.symlink(
        repository_ctx.path(repository_ctx.attr.maven_install_json),
        repository_ctx.path("imported_maven_install.json"),
    )
    maven_install_json_content = json_parse(
        repository_ctx.read(
            repository_ctx.path("imported_maven_install.json"),
        ),
        fail_on_invalid = False,
    )

    # Validation steps for maven_install.json.

    # First, validate that we can parse the JSON file.
    if maven_install_json_content == None:
        fail("Failed to parse %s. Is this file valid JSON? The file may have been corrupted." % repository_ctx.path(repository_ctx.attr.maven_install_json) +
             "Consider regenerating maven_install.json with the following steps:\n" +
             "  1. Remove the maven_install_json attribute from your `maven_install` declaration for `@%s`.\n" % repository_ctx.name +
             "  2. Regenerate `maven_install.json` by running the command: bazel run @%s//:pin" % repository_ctx.name +
             "  3. Add `maven_install_json = \"//:maven_install.json\"` into your `maven_install` declaration.")

    # Then, validate that there's a dependency_tree element in the parsed JSON.
    if maven_install_json_content.get("dependency_tree") == None:
        fail("Failed to parse %s. " % repository_ctx.path(repository_ctx.attr.maven_install_json) +
             "It is not a valid maven_install.json file. Has this " +
             "file been modified manually?")

    dep_tree = maven_install_json_content["dependency_tree"]

    # Then, check to see if we need to repin our deps because inputs have changed
    if dep_tree.get("__INPUT_ARTIFACTS_HASH") == None:
        print("NOTE: %s_install.json does not contain a signature of the required artifacts. " % repository_ctx.name +
              "This feature ensures that the build does not use stale dependencies when the inputs " +
              "have changed. To generate this signature, run 'bazel run @unpinned_%s//:pin'." % repository_ctx.name)
    else:
        computed_artifacts_hash = compute_dependency_inputs_signature(repository_ctx.attr.artifacts)
        if computed_artifacts_hash != dep_tree.get("__INPUT_ARTIFACTS_HASH"):
            if _fail_if_repin_required(repository_ctx):
                fail("%s_install.json contains an invalid input signature and must be regenerated. " % (repository_ctx.name) +
                     "This typically happens when the maven_install artifacts have been changed but not repinned. " +
                     "PLEASE DO NOT MODIFY THIS FILE DIRECTLY! To generate a new " +
                     "%s_install.json and re-pin the artifacts, either run:\n" % repository_ctx.name +
                     " REPIN=1 bazel run @unpinned_%s//:pin\n" % repository_ctx.name +
                     "or:\n" +
                     " 1) Set 'fail_if_repin_required' to 'False' in 'maven_install'\n" +
                     " 2) Run 'bazel run @unpinned_%s//:pin'\n" % repository_ctx.name +
                     " 3) Reset 'fail_if_repin_required' to 'True' in 'maven_install'\n\n")
            else:
                print("The inputs to %s_install.json have changed, but the lock file has not been regenerated. " % repository_ctx.name +
                      "Consider running 'bazel run @unpinned_%s//:pin'" % repository_ctx.name)

    dep_tree_signature = dep_tree.get("__RESOLVED_ARTIFACTS_HASH")

    if dep_tree_signature == None:
        print("NOTE: %s_install.json does not contain a signature entry of the dependency tree. " % repository_ctx.name +
              "This feature ensures that the file is not modified manually. To generate this " +
              "signature, run 'bazel run @unpinned_%s//:pin'." % repository_ctx.name)
    elif _compute_dependency_tree_signature(dep_tree["dependencies"]) != dep_tree_signature:
        # Then, validate that the signature provided matches the contents of the dependency_tree.
        # This is to stop users from manually modifying maven_install.json.
        fail("%s_install.json contains an invalid signature and may be corrupted. " % repository_ctx.name +
             "PLEASE DO NOT MODIFY THIS FILE DIRECTLY! To generate a new " +
             "%s_install.json and re-pin the artifacts, follow these steps: \n\n" % repository_ctx.name +
             "  1) In your WORKSPACE file, comment or remove the 'maven_install_json' attribute in 'maven_install'.\n" +
             "  2) Run 'bazel run @%s//:pin'.\n" % repository_ctx.name +
             "  3) Uncomment or re-add the 'maven_install_json' attribute in 'maven_install'.\n\n")

    # Create the list of http_file repositories for each of the artifacts
    # in maven_install.json. This will be loaded additionally like so:
    #
    # load("@maven//:defs.bzl", "pinned_maven_install")
    # pinned_maven_install()
    http_files = [
        "load(\"@bazel_tools//tools/build_defs/repo:http.bzl\", \"http_file\")",
        "load(\"@bazel_tools//tools/build_defs/repo:utils.bzl\", \"maybe\")",
        "def pinned_maven_install():",
    ]
    netrc_entries = {}

    for artifact in dep_tree["dependencies"]:
        if artifact.get("url") != None:
            http_file_repository_name = escape(artifact["coord"])
            http_files.extend([
                "    http_file(",
                "        name = \"%s\"," % http_file_repository_name,
                "        sha256 = \"%s\"," % artifact["sha256"],
                # repository_ctx should point to external/$repository_ctx.name
                # The http_file should point to external/$http_file_repository_name
                # File-path is relative defined from http_file traveling to repository_ctx.
                "        netrc = \"../%s/netrc\"," % (repository_ctx.name),
            ])
            if artifact.get("mirror_urls") != None:
                http_files.append("        urls = %s," % repr(
                    [remove_auth_from_url(url) for url in artifact["mirror_urls"]],
                ))
                netrc_entries = add_netrc_entries_from_mirror_urls(netrc_entries, artifact["mirror_urls"])
            else:
                # For backwards compatibility. mirror_urls is a field added in a
                # later version than the url field, so not all maven_install.json
                # contains the mirror_urls field.
                http_files.append("        urls = [\"%s\"]," % artifact["url"])
            http_files.append("    )")

    http_files.extend(_get_jq_http_files())

    repository_ctx.file("defs.bzl", "\n".join(http_files), executable = False)
    repository_ctx.file(
        "netrc",
        "\n".join(
            repository_ctx.attr.additional_netrc_lines +
            get_home_netrc_contents(repository_ctx).splitlines() +
            get_netrc_lines_from_entries(netrc_entries),
        ),
        executable = False,
    )

    repository_ctx.report_progress("Generating BUILD targets..")
    (generated_imports, jar_versionless_target_labels) = parser.generate_imports(
        repository_ctx = repository_ctx,
        dep_tree = dep_tree,
        explicit_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
        },
        neverlink_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
            if a.get("neverlink", False)
        },
        testonly_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
            if a.get("testonly", False)
        },
        override_targets = repository_ctx.attr.override_targets,
    )

    repository_ctx.template(
        "compat_repository.bzl",
        repository_ctx.attr._compat_repository,
        substitutions = {},
        executable = False,
    )

    repository_ctx.file(
        "BUILD",
        (_BUILD + _BUILD_OUTDATED).format(
            visibility = "private" if repository_ctx.attr.strict_visibility else "public",
            repository_name = repository_ctx.name,
            imports = generated_imports,
            aar_import_statement = _get_aar_import_statement_or_empty_str(repository_ctx),
        ),
        executable = False,
    )

    _add_outdated_files(repository_ctx, artifacts, repositories)

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
                executable = False,
            )

def split_url(url):
    protocol = url[:url.find("://")]
    url_without_protocol = url[url.find("://") + 3:]
    url_parts = url_without_protocol.split("/")
    return protocol, url_parts

def remove_auth_from_url(url):
    """Returns url without `user:pass@` or `user@`."""
    if "@" not in url:
        return url
    protocol, url_parts = split_url(url)
    host = url_parts[0]
    if "@" not in host:
        return url
    last_index = host.rfind("@", 0, None)
    userless_host = host[last_index + 1:]
    new_url = "{}://{}".format(protocol, "/".join([userless_host] + url_parts[1:]))
    return new_url

def infer_artifact_path_from_primary_and_repos(primary_url, repository_urls):
    """Returns the artifact path inferred by comparing primary_url with urls in repository_urls.

    When given a list of repository urls and a primary url that has a repository url as a prefix and a maven artifact
    path as a suffix, this method will try to determine what the maven artifact path is and return it.

    This method has some handling for basic http-based auth parsing and will do a url comparison with the user:pass@
    portion stripped.

    Ex.
    infer_artifact_path_from_primary_and_repos(
        "http://a:b@c/group/path/to/artifact/file.jar",
        ["http://c"])
    == "group/path/to/artifact/file.jar"

    Returns:
        String of the artifact path used by maven to find a particular artifact. Does not have a leading slash (`/`).
    """
    userless_repository_urls = [remove_auth_from_url(r.rstrip("/")) for r in repository_urls]
    userless_primary_url = remove_auth_from_url(primary_url)
    primary_artifact_path = None
    for url in userless_repository_urls:
        if userless_primary_url.find(url) != -1:
            primary_artifact_path = userless_primary_url[len(url) + 1:]
            break
    return primary_artifact_path

def _deduplicate_artifacts(dep_tree):
    deduped_artifacts = {}
    null_artifacts = []
    for artifact in dep_tree["dependencies"]:
        if artifact["file"] == None:
            null_artifacts.append(artifact)
            continue
        if artifact["file"] in deduped_artifacts:
            continue
        deduped_artifacts[artifact["file"]] = artifact
    dep_tree.update({"dependencies": deduped_artifacts.values() + null_artifacts})
    return dep_tree

# Get the path to the cache directory containing Coursier-downloaded artifacts.
#
# This method is public for testing.
def get_coursier_cache_or_default(repository_ctx, use_unsafe_shared_cache):
    # If we're not using the unsafe shared cache use 'external/<this repo>/v1/'.
    # 'v1' is the current version of the Coursier cache.
    if not use_unsafe_shared_cache:
        return "v1"

    os_env = repository_ctx.os.environ
    coursier_cache_env_var = os_env.get("COURSIER_CACHE")
    if coursier_cache_env_var:
        # This is an absolute path.
        return coursier_cache_env_var

    # cache locations from https://get-coursier.io/docs/2.0.0-RC5-3/cache.html#default-location
    # Use linux as the default cache directory
    default_cache_dir = "%s/.cache/coursier/v1" % os_env.get("HOME")
    if _is_windows(repository_ctx):
        default_cache_dir = "%s/Coursier/cache/v1" % os_env.get("LOCALAPPDATA").replace("\\", "/")
    elif _is_macos(repository_ctx):
        default_cache_dir = "%s/Library/Caches/Coursier/v1" % os_env.get("HOME")

    # Logic based on # https://github.com/coursier/coursier/blob/f48c1c6b01ac5b720e66e06cf93587b21d030e8c/modules/paths/src/main/java/coursier/paths/CoursierPaths.java#L60
    if _is_directory(repository_ctx, default_cache_dir):
        return default_cache_dir
    elif _is_directory(repository_ctx, "%s/.coursier" % os_env.get("HOME")):
        return "%s/.coursier/cache/v1" % os_env.get("HOME")

    return default_cache_dir

def make_coursier_dep_tree(
        repository_ctx,
        artifacts,
        excluded_artifacts,
        repositories,
        version_conflict_policy,
        fail_on_missing_checksum,
        fetch_sources,
        fetch_javadoc,
        use_unsafe_shared_cache,
        timeout,
        report_progress_prefix = ""):
    # Set up artifact exclusion, if any. From coursier fetch --help:
    #
    # Path to the local exclusion file. Syntax: <org:name>--<org:name>. `--` means minus. Example file content:
    # com.twitter.penguin:korean-text--com.twitter:util-tunable-internal_2.11
    # org.apache.commons:commons-math--com.twitter.search:core-query-nodes
    # Behavior: If root module A excludes module X, but root module B requires X, module X will still be fetched.
    artifact_coordinates = []
    exclusion_lines = []
    for a in artifacts:
        artifact_coordinates.append(utils.artifact_coordinate(a))
        if "exclusions" in a:
            for e in a["exclusions"]:
                exclusion_lines.append(":".join([a["group"], a["artifact"]]) +
                                       "--" +
                                       ":".join([e["group"], e["artifact"]]))

    cmd = _generate_java_jar_command(repository_ctx, repository_ctx.path("coursier"))
    cmd.extend(["fetch"])

    cmd.extend(artifact_coordinates)
    if version_conflict_policy == "pinned":
        for coord in artifact_coordinates:
            # Undo any `,classifier=` suffix from `utils.artifact_coordinate`.
            cmd.extend(["--force-version", coord.split(",classifier=")[0]])
    cmd.extend(["--artifact-type", ",".join(SUPPORTED_PACKAGING_TYPES + ["src", "doc"])])
    cmd.append("--verbose" if _is_verbose(repository_ctx) else "--quiet")
    cmd.append("--no-default")
    cmd.extend(["--json-output-file", "dep-tree.json"])

    if fail_on_missing_checksum:
        cmd.extend(["--checksum", "SHA-1,MD5"])
    else:
        cmd.extend(["--checksum", "SHA-1,MD5,None"])

    if len(exclusion_lines) > 0:
        repository_ctx.file("exclusion-file.txt", "\n".join(exclusion_lines), False)
        cmd.extend(["--local-exclude-file", "exclusion-file.txt"])
    for repository in repositories:
        cmd.extend(["--repository", repository["repo_url"]])
        if "credentials" in repository:
            cmd.extend(["--credentials", utils.repo_credentials(repository)])
    for a in excluded_artifacts:
        cmd.extend(["--exclude", ":".join([a["group"], a["artifact"]])])

    if fetch_sources or fetch_javadoc:
        if fetch_sources:
            cmd.append("--sources")
        if fetch_javadoc:
            cmd.append("--javadoc")
        cmd.append("--default=true")

    environment = {}
    if not use_unsafe_shared_cache and not repository_ctx.attr.name.startswith("unpinned_"):
        coursier_cache_location = get_coursier_cache_or_default(
            repository_ctx,
            use_unsafe_shared_cache,
        )
        cmd.extend(["--cache", coursier_cache_location])  # Download into $output_base/external/$maven_repo_name/v1

        # If not using the shared cache and the user did not specify a COURSIER_CACHE, set the default
        # value to prevent Coursier from writing into home directories.
        # https://github.com/bazelbuild/rules_jvm_external/issues/301
        # https://github.com/coursier/coursier/blob/1cbbf39b88ee88944a8d892789680cdb15be4714/modules/paths/src/main/java/coursier/paths/CoursierPaths.java#L29-L56
        environment = {"COURSIER_CACHE": str(repository_ctx.path(coursier_cache_location))}

    repository_ctx.report_progress(
        "%sResolving and fetching the transitive closure of %s artifact(s).." % (
            report_progress_prefix,
            len(artifact_coordinates),
        ),
    )

    exec_result = repository_ctx.execute(
        cmd,
        timeout = timeout,
        environment = environment,
        quiet = not _is_verbose(repository_ctx),
    )
    if (exec_result.return_code != 0):
        fail("Error while fetching artifact with coursier: " + exec_result.stderr)

    return _deduplicate_artifacts(json_parse(repository_ctx.read(repository_ctx.path(
        "dep-tree.json",
    ))))

def _download_jq(repository_ctx):
    jq_version = None

    for (os, value) in JQ_VERSIONS.items():
        repository_ctx.download(value.url, "jq-%s" % os, sha256 = value.sha256, executable = True)

def _coursier_fetch_impl(repository_ctx):
    # Not using maven_install.json, so we resolve and fetch from scratch.
    # This takes significantly longer as it doesn't rely on any local
    # caches and uses Coursier's own download mechanisms.

    # Download Coursier's standalone (deploy) jar from Maven repositories.
    coursier_download_urls = [
        COURSIER_CLI_GITHUB_ASSET_URL,
        COURSIER_CLI_BAZEL_MIRROR_URL,
    ]

    coursier_url_from_env = repository_ctx.os.environ.get("COURSIER_URL")
    if coursier_url_from_env != None:
        coursier_download_urls.append(coursier_url_from_env)

    repository_ctx.download(coursier_download_urls, "coursier", sha256 = COURSIER_CLI_SHA256, executable = True)
    _download_jq(repository_ctx)

    # Try running coursier once
    cmd = _generate_java_jar_command(repository_ctx, repository_ctx.path("coursier"))

    # Add --help because calling the default coursier command on Windows will
    # hang waiting for input
    cmd.append("--help")
    exec_result = repository_ctx.execute(
        cmd,
        quiet = not _is_verbose(repository_ctx),
    )
    if exec_result.return_code != 0:
        fail("Unable to run coursier: " + exec_result.stderr)

    _windows_check(repository_ctx)

    # Deserialize the spec blobs
    repositories = []
    for repository in repository_ctx.attr.repositories:
        repositories.append(json_parse(repository))

    artifacts = []
    for artifact in repository_ctx.attr.artifacts:
        artifacts.append(json_parse(artifact))

    excluded_artifacts = []
    for artifact in repository_ctx.attr.excluded_artifacts:
        excluded_artifacts.append(json_parse(artifact))

    # Once coursier finishes a fetch, it generates a tree of artifacts and their
    # transitive dependencies in a JSON file. We use that as the source of truth
    # to generate the repository's BUILD file.
    #
    # Coursier generates duplicate artifacts sometimes. Deduplicate them using
    # the file name value as the key.
    dep_tree = make_coursier_dep_tree(
        repository_ctx,
        artifacts,
        excluded_artifacts,
        repositories,
        repository_ctx.attr.version_conflict_policy,
        repository_ctx.attr.fail_on_missing_checksum,
        repository_ctx.attr.fetch_sources,
        repository_ctx.attr.fetch_javadoc,
        repository_ctx.attr.use_unsafe_shared_cache,
        repository_ctx.attr.resolve_timeout,
    )

    # Fetch all possible jetified artifacts. We will wire them up later.
    if repository_ctx.attr.jetify:
        extra_jetify_artifacts = []
        for artifact in dep_tree["dependencies"]:
            artifact_coord = parse.parse_maven_coordinate(artifact["coord"])
            jetify_coord_tuple = jetify_maven_coord(
                artifact_coord["group"],
                artifact_coord["artifact"],
                artifact_coord["version"],
            )
            if jetify_coord_tuple:
                artifact_coord["group"] = jetify_coord_tuple[0]
                artifact_coord["artifact"] = jetify_coord_tuple[1]
                artifact_coord["version"] = jetify_coord_tuple[2]
                extra_jetify_artifacts.append(artifact_coord)
        dep_tree = make_coursier_dep_tree(
            repository_ctx,
            # Order is important due to version conflict resolution. "pinned" will take the last
            # version that is provided so having the explicit artifacts last makes those versions
            # stick.
            extra_jetify_artifacts + artifacts,
            excluded_artifacts,
            repositories,
            repository_ctx.attr.version_conflict_policy,
            repository_ctx.attr.fail_on_missing_checksum,
            repository_ctx.attr.fetch_sources,
            repository_ctx.attr.fetch_javadoc,
            repository_ctx.attr.use_unsafe_shared_cache,
            repository_ctx.attr.resolve_timeout,
            report_progress_prefix = "Second pass for Jetified Artifacts: ",
        )

    # Reconstruct the original URLs from the relative path to the artifact,
    # which encodes the URL components for the protocol, domain, and path to
    # the file.

    hasher_command = _generate_java_jar_command(
        repository_ctx,
        repository_ctx.path(repository_ctx.attr._sha256_hasher),
    )
    files_to_hash = []
    jetify_include_dict = {k: None for k in repository_ctx.attr.jetify_include_list}
    jetify_all = repository_ctx.attr.jetify and repository_ctx.attr.jetify_include_list == JETIFY_INCLUDE_LIST_JETIFY_ALL

    for artifact in dep_tree["dependencies"]:
        # Some artifacts don't contain files; they are just parent artifacts
        # to other artifacts.
        if artifact["file"] == None:
            continue

        coord_split = artifact["coord"].split(":")
        coord_unversioned = "{}:{}".format(coord_split[0], coord_split[1])
        should_jetify = jetify_all or (repository_ctx.attr.jetify and coord_unversioned in jetify_include_dict)
        if should_jetify:
            artifact["directDependencies"] = jetify_artifact_dependencies(artifact["directDependencies"])
            artifact["dependencies"] = jetify_artifact_dependencies(artifact["dependencies"])

        # Normalize paths in place here.
        artifact.update({"file": _normalize_to_unix_path(artifact["file"])})

        if repository_ctx.attr.use_unsafe_shared_cache or repository_ctx.attr.name.startswith("unpinned_"):
            artifact.update({"file": _relativize_and_symlink_file(repository_ctx, artifact["file"])})

        # Coursier saves the artifacts into a subdirectory structure
        # that mirrors the URL where the artifact's fetched from. Using
        # this, we can reconstruct the original URL.
        primary_url_parts = []
        filepath_parts = artifact["file"].split("/")
        protocol = None

        # Only support http/https transports
        for part in filepath_parts:
            if part == "http" or part == "https":
                protocol = part
                break
        if protocol == None:
            fail("Only artifacts downloaded over http(s) are supported: %s" % artifact["coord"])
        primary_url_parts.extend([protocol, "://"])
        for part in filepath_parts[filepath_parts.index(protocol) + 1:]:
            primary_url_parts.extend([part, "/"])
        primary_url_parts.pop()  # pop the final "/"

        # Coursier encodes:
        # - ':' as '%3A'
        # - '@' as '%40'
        #
        # The primary_url is the url from which Coursier downloaded the jar from. It looks like this:
        # https://repo1.maven.org/maven2/org/threeten/threetenbp/1.3.3/threetenbp-1.3.3.jar
        primary_url = "".join(primary_url_parts).replace("%3A", ":").replace("%40", "@")
        artifact.update({"url": primary_url})

        # The repository for the primary_url has to be one of the repositories provided through
        # maven_install. Since Maven artifact URLs are standardized, we can make the `http_file`
        # targets more robust by replicating the primary url for each specified repository url.
        #
        # It does not matter if the artifact is on a repository or not, since http_file takes
        # care of 404s.
        #
        # If the artifact does exist, Bazel's HttpConnectorMultiplexer enforces the SHA-256 checksum
        # is correct. By applying the SHA-256 checksum verification across all the mirrored files,
        # we get increased robustness in the case where our primary artifact has been tampered with,
        # and we somehow ended up using the tampered checksum. Attackers would need to tamper *all*
        # mirrored artifacts.
        #
        # See https://github.com/bazelbuild/bazel/blob/77497817b011f298b7f3a1138b08ba6a962b24b8/src/main/java/com/google/devtools/build/lib/bazel/repository/downloader/HttpConnectorMultiplexer.java#L103
        # for more information on how Bazel's HTTP multiplexing works.
        #
        # TODO(https://github.com/bazelbuild/rules_jvm_external/issues/186): Make this work with
        # basic auth.
        repository_urls = [r["repo_url"].rstrip("/") for r in repositories]
        primary_artifact_path = infer_artifact_path_from_primary_and_repos(primary_url, repository_urls)

        mirror_urls = [url + "/" + primary_artifact_path for url in repository_urls]
        artifact.update({"mirror_urls": mirror_urls})

        files_to_hash.append(repository_ctx.path(artifact["file"]))

    # Avoid argument limits by putting list of files to hash into a file
    repository_ctx.file(
        "hasher_argsfile",
        "\n".join([str(f) for f in files_to_hash]) + "\n",
        executable = False,
    )
    exec_result = repository_ctx.execute(
        hasher_command + ["--argsfile", repository_ctx.path("hasher_argsfile")],
        quiet = not _is_verbose(repository_ctx),
    )
    if exec_result.return_code != 0:
        fail("Error while obtaining the sha256 checksums: " + exec_result.stderr)

    shas = {}
    for line in exec_result.stdout.splitlines():
        parts = line.split(" ")
        path = str(repository_ctx.path(parts[1]))
        shas[path] = parts[0]

    for artifact in dep_tree["dependencies"]:
        file = artifact["file"]
        if file == None:
            continue
        artifact.update({"sha256": shas[str(repository_ctx.path(file))]})

    dep_tree.update({
        "__AUTOGENERATED_FILE_DO_NOT_MODIFY_THIS_FILE_MANUALLY": "THERE_IS_NO_DATA_ONLY_ZUUL",
        "__RESOLVED_ARTIFACTS_HASH": _compute_dependency_tree_signature(dep_tree["dependencies"]),
        "__INPUT_ARTIFACTS_HASH": compute_dependency_inputs_signature(repository_ctx.attr.artifacts),
    })

    repository_ctx.report_progress("Generating BUILD targets..")
    (generated_imports, jar_versionless_target_labels) = parser.generate_imports(
        repository_ctx = repository_ctx,
        dep_tree = dep_tree,
        explicit_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
        },
        neverlink_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
            if a.get("neverlink", False)
        },
        testonly_artifacts = {
            a["group"] + ":" + a["artifact"] + (":" + a["classifier"] if "classifier" in a else ""): True
            for a in artifacts
            if a.get("testonly", False)
        },
        override_targets = repository_ctx.attr.override_targets,
    )

    # This repository rule can be either in the pinned or unpinned state, depending on when
    # the user invokes artifact pinning. Normalize the repository name here.
    if repository_ctx.name.startswith("unpinned_"):
        repository_name = repository_ctx.name[len("unpinned_"):]
        outdated_build_file_content = ""
    else:
        repository_name = repository_ctx.name

        # Add outdated artifact files if this is a pinned repo
        outdated_build_file_content = _BUILD_OUTDATED
        _add_outdated_files(repository_ctx, artifacts, repositories)

    repository_ctx.file(
        "BUILD",
        (_BUILD + _BUILD_PIN + outdated_build_file_content).format(
            visibility = "private" if repository_ctx.attr.strict_visibility else "public",
            repository_name = repository_name,
            imports = generated_imports,
            aar_import_statement = _get_aar_import_statement_or_empty_str(repository_ctx),
        ),
        executable = False,
    )

    # If maven_install.json has already been used in maven_install,
    # we don't need to instruct user to update WORKSPACE and load pinned_maven_install.
    # If maven_install.json is not used yet, provide complete instructions.
    #
    # Also support custom locations for maven_install.json and update the pin.sh script
    # accordingly.
    predefined_maven_install = bool(repository_ctx.attr.maven_install_json)
    if predefined_maven_install:
        package_path = repository_ctx.attr.maven_install_json.package
        file_name = repository_ctx.attr.maven_install_json.name
        if package_path == "":
            maven_install_location = file_name  # e.g. some.json
        else:
            maven_install_location = "/".join([package_path, file_name])  # e.g. path/to/some.json
    else:
        # Default maven_install.json file name.
        maven_install_location = "{repository_name}_install.json"

    # Expose the script to let users pin the state of the fetch in
    # `<workspace_root>/maven_install.json`.
    #
    # $ bazel run @unpinned_maven//:pin
    #
    # Create the maven_install.json export script for unpinned repositories.
    dependency_tree_json = "{ \"dependency_tree\": " + repr(dep_tree).replace("None", "null") + "}"
    repository_ctx.template(
        "pin.sh",
        repository_ctx.attr._pin,
        {
            "{dependency_tree_json}": dependency_tree_json,
            "{maven_install_location}": "$BUILD_WORKSPACE_DIRECTORY/" + maven_install_location,
            "{predefined_maven_install}": str(predefined_maven_install),
            "{repository_name}": repository_name,
        },
        executable = True,
    )

    # Generate 'defs.bzl' with just the dependencies for ':pin'.
    http_files = [
        "load(\"@bazel_tools//tools/build_defs/repo:http.bzl\", \"http_file\")",
        "load(\"@bazel_tools//tools/build_defs/repo:utils.bzl\", \"maybe\")",
        "def pinned_maven_install():",
    ] + _get_jq_http_files()
    repository_ctx.file(
        "defs.bzl",
        "\n".join(http_files),
        executable = False,
    )

    # Generate a compatibility layer of external repositories for all jar artifacts.
    if repository_ctx.attr.generate_compat_repositories:
        repository_ctx.template(
            "compat_repository.bzl",
            repository_ctx.attr._compat_repository,
            substitutions = {},
            executable = False,
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
            executable = False,
        )

pinned_coursier_fetch = repository_rule(
    attrs = {
        "_compat_repository": attr.label(default = "//:private/compat_repository.bzl"),
        "_outdated": attr.label(default = "//:private/outdated.sh"),
        "repositories": attr.string_list(),  # list of repository objects, each as json
        "artifacts": attr.string_list(),  # list of artifact objects, each as json
        "fetch_sources": attr.bool(default = False),
        "fetch_javadoc": attr.bool(default = False),
        "generate_compat_repositories": attr.bool(default = False),  # generate a compatible layer with repositories for each artifact
        "maven_install_json": attr.label(allow_single_file = True),
        "override_targets": attr.string_dict(default = {}),
        "strict_visibility": attr.bool(
            doc = """Controls visibility of transitive dependencies.

            If "True", transitive dependencies are private and invisible to user's rules.
            If "False", transitive dependencies are public and visible to user's rules.
            """,
            default = False,
        ),
        "jetify": attr.bool(doc = "Runs the AndroidX [Jetifier](https://developer.android.com/studio/command-line/jetifier) tool on artifacts specified in jetify_include_list. If jetify_include_list is not specified, run Jetifier on all artifacts.", default = False),
        "jetify_include_list": attr.string_list(doc = "List of artifacts that need to be jetified in `groupId:artifactId` format. By default all artifacts are jetified if `jetify` is set to True.", default = JETIFY_INCLUDE_LIST_JETIFY_ALL),
        "additional_netrc_lines": attr.string_list(doc = "Additional lines prepended to the netrc file used by `http_file` (with `maven_install_json` only).", default = []),
        "fail_if_repin_required": attr.bool(doc = "Whether to fail the build if the maven_artifact inputs have changed but the lock file has not been repinned.", default = False),
        "use_starlark_android_rules": attr.bool(default = False, doc = "Whether to use the native or Starlark version of the Android rules."),
        "aar_import_bzl_label": attr.string(default = DEFAULT_AAR_IMPORT_LABEL, doc = "The label (as a string) to use to import aar_import from"),
    },
    implementation = _pinned_coursier_fetch_impl,
)

coursier_fetch = repository_rule(
    attrs = {
        "_sha256_hasher": attr.label(default = "//private/tools/prebuilt:hasher_deploy.jar"),
        "_pin": attr.label(default = "//:private/pin.sh"),
        "_compat_repository": attr.label(default = "//:private/compat_repository.bzl"),
        "_outdated": attr.label(default = "//:private/outdated.sh"),
        "repositories": attr.string_list(),  # list of repository objects, each as json
        "artifacts": attr.string_list(),  # list of artifact objects, each as json
        "fail_on_missing_checksum": attr.bool(default = True),
        "fetch_sources": attr.bool(default = False),
        "fetch_javadoc": attr.bool(default = False),
        "use_unsafe_shared_cache": attr.bool(default = False),
        "excluded_artifacts": attr.string_list(default = []),  # list of artifacts to exclude
        "generate_compat_repositories": attr.bool(default = False),  # generate a compatible layer with repositories for each artifact
        "version_conflict_policy": attr.string(
            doc = """Policy for user-defined vs. transitive dependency version conflicts

            If "pinned", choose the user-specified version in maven_install unconditionally.
            If "default", follow Coursier's default policy.
            """,
            default = "default",
            values = [
                "default",
                "pinned",
            ],
        ),
        "maven_install_json": attr.label(allow_single_file = True),
        "override_targets": attr.string_dict(default = {}),
        "strict_visibility": attr.bool(
            doc = """Controls visibility of transitive dependencies

            If "True", transitive dependencies are private and invisible to user's rules.
            If "False", transitive dependencies are public and visible to user's rules.
            """,
            default = False,
        ),
        "resolve_timeout": attr.int(default = 600),
        "jetify": attr.bool(doc = "Runs the AndroidX [Jetifier](https://developer.android.com/studio/command-line/jetifier) tool on artifacts specified in jetify_include_list. If jetify_include_list is not specified, run Jetifier on all artifacts.", default = False),
        "jetify_include_list": attr.string_list(doc = "List of artifacts that need to be jetified in `groupId:artifactId` format. By default all artifacts are jetified if `jetify` is set to True.", default = JETIFY_INCLUDE_LIST_JETIFY_ALL),
        "java_binary": attr.label(doc = "Full path to a java executable", default = None),
        "use_starlark_android_rules": attr.bool(default = False, doc = "Whether to use the native or Starlark version of the Android rules."),
        "aar_import_bzl_label": attr.string(default = DEFAULT_AAR_IMPORT_LABEL, doc = "The label (as a string) to use to import aar_import from"),
    },
    environ = [
        "JAVA_HOME",
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "no_proxy",
        "NO_PROXY",
        "COURSIER_CACHE",
        "COURSIER_OPTS",
        "COURSIER_URL",
        "RJE_VERBOSE",
    ],
    implementation = _coursier_fetch_impl,
)
