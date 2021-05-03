workspace(name = "rules_jvm_external")

android_sdk_repository(
    name = "androidsdk",
    api_level = 28,
    build_tools_version = "28.0.2",
)

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load(
    "//:private/versions.bzl",
    "COURSIER_CLI_GITHUB_ASSET_URL",
    "COURSIER_CLI_HTTP_FILE_NAME",
    "COURSIER_CLI_SHA256",
)

http_file(
    name = COURSIER_CLI_HTTP_FILE_NAME,
    sha256 = COURSIER_CLI_SHA256,
    urls = [COURSIER_CLI_GITHUB_ASSET_URL],
)

# Begin Skylib dependencies

http_archive(
    name = "bazel_skylib",
    sha256 = "97e70364e9249702246c0e9444bccdc4b847bed1eb03c5a3ece4f83dfe6abc44",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.0.2/bazel-skylib-1.0.2.tar.gz",
        "https://github.com/bazelbuild/bazel-skylib/releases/download/1.0.2/bazel-skylib-1.0.2.tar.gz",
    ],
)

load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

# End Skylib dependencies

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

http_archive(
    name = "io_bazel_stardoc",
    sha256 = "4a355dccc713458071f441f3dafd7452b3111c53cde554d0847b9a82d657149e",
    strip_prefix = "stardoc-4378e9b6bb2831de7143580594782f538f461180",
    url = "https://github.com/bazelbuild/stardoc/archive/4378e9b6bb2831de7143580594782f538f461180.zip",
)

# Stardoc also depends on skydoc_repositories, rules_sass, rules_nodejs, but our
# usage of Stardoc (scripts/generate_docs) doesn't require any of these
# dependencies. So, we omit them to keep the WORKSPACE file simpler.
# https://skydoc.bazel.build/docs/getting_started_stardoc.html

load("//:repositories.bzl", "rules_jvm_external_deps")

rules_jvm_external_deps()

load("//:setup.bzl", "rules_jvm_external_setup")

rules_jvm_external_setup()

# Begin test dependencies

load("//:defs.bzl", "maven_install")
load("//:specs.bzl", "maven")

maven_install(
    name = "ivy_repo",
    artifacts = [
        "com.typesafe.sbt:sbt-native-packager;sbtVersion=1.0;scalaVersion=2.12:1.8.1"
    ],
    repositories = [
        "ivy:https://repo.scala-sbt.org/scalasbt/sbt-plugin-releases/[organization]/[module]/(scala_[scalaVersion]/)(sbt_[sbtVersion]/)[revision]/[type]s/[artifact](-[classifier]).[ext]",
        "https://repo1.maven.org/maven2",
    ],
)

maven_install(
    name = "outdated",
    artifacts = [
        "org.apache.maven:maven-artifact:3.6.3",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

maven_install(
    artifacts = [
        "com.google.guava:guava:27.0-jre",
        "org.hamcrest:hamcrest-core:2.1",
    ],
    maven_install_json = "@rules_jvm_external//:maven_install.json",
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

load("@maven//:defs.bzl", "pinned_maven_install")

pinned_maven_install()

maven_install(
    name = "unsafe_shared_cache",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
    ],
    fetch_sources = True,
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
    use_unsafe_shared_cache = True,
)

maven_install(
    name = "unsafe_shared_cache_with_pinning",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
    ],
    fetch_sources = True,
    maven_install_json = "//tests/custom_maven_install:unsafe_shared_cache_with_pinning_install.json",
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
    use_unsafe_shared_cache = True,
)

load("@unsafe_shared_cache_with_pinning//:defs.bzl", "pinned_maven_install")

pinned_maven_install()

maven_install(
    name = "exclusion_testing",
    artifacts = [
        maven.artifact(
            group = "com.google.guava",
            artifact = "guava",
            version = "27.0-jre",
            exclusions = [
                maven.exclusion(
                    group = "org.codehaus.mojo",
                    artifact = "animal-sniffer-annotations",
                ),
                "com.google.j2objc:j2objc-annotations",
            ],
        ),
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

maven_install(
    name = "global_exclusion_testing",
    artifacts = [
        "com.google.guava:guava:27.0-jre",  # depends on animal-sniffer-annotations and j2objc-annotations
        "com.squareup.okhttp3:okhttp:3.14.1",  # depends on animal-sniffer-annotations
        "com.diffplug.durian:durian-core:1.2.0",  # depends on animal-sniffer-annotations and j2objc-annotations
    ],
    excluded_artifacts = [
        maven.exclusion(
            group = "org.codehaus.mojo",
            artifact = "animal-sniffer-annotations",
        ),
        "com.google.j2objc:j2objc-annotations",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

maven_install(
    name = "manifest_stamp_testing",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
        "javax.inject:javax.inject:1",
        "org.apache.beam:beam-sdks-java-core:2.15.0",
        "org.bouncycastle:bcprov-jdk15on:1.64",
    ],
    maven_install_json = "//tests/custom_maven_install:manifest_stamp_testing_install.json",
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

load("@manifest_stamp_testing//:defs.bzl", "pinned_maven_install")

pinned_maven_install()

# These artifacts helped discover limitations by the Maven resolver. Each
# artifact listed here *must have* an accompanying issue. We build_test these
# targets to ensure that they remain supported by the rule.
maven_install(
    name = "regression_testing",
    artifacts = [
        # https://github.com/bazelbuild/rules_jvm_external/issues/74
        "org.pantsbuild:jarjar:1.6.6",
        # https://github.com/bazelbuild/rules_jvm_external/issues/59
        "junit:junit:4.12",
        "org.jetbrains.kotlin:kotlin-test:1.3.21",
        # https://github.com/bazelbuild/rules_jvm_external/issues/101
        # As referenced in the issue, daml is not available anymore, hence
        # replacing with another artifact with a classifier.
        "org.eclipse.jetty:jetty-http:jar:tests:9.4.20.v20190813",
        # https://github.com/bazelbuild/rules_jvm_external/issues/116
        "org.eclipse.jetty.orbit:javax.servlet:3.0.0.v201112011016",
        # https://github.com/bazelbuild/rules_jvm_external/issues/92#issuecomment-478430167
        maven.artifact(
            "com.squareup",
            "javapoet",
            "1.11.1",
            neverlink = True,
        ),
        # https://github.com/bazelbuild/rules_jvm_external/issues/98
        "com.github.fommil.netlib:all:1.1.2",
        "nz.ac.waikato.cms.weka:weka-stable:3.8.1",
        # https://github.com/bazelbuild/rules_jvm_external/issues/111
        "com.android.support:appcompat-v7:aar:28.0.0",
        "com.google.android.gms:play-services-base:16.1.0",
        # https://github.com/bazelbuild/rules_jvm_external/issues/119#issuecomment-484278260
        "org.apache.flink:flink-test-utils_2.12:1.8.0",
        # https://github.com/bazelbuild/rules_jvm_external/issues/170
        "ch.epfl.scala:compiler-interface:1.3.0-M4+20-c8a2f9bd",
        # https://github.com/bazelbuild/rules_jvm_external/issues/172
        "org.openjfx:javafx-base:11.0.1",
        # https://github.com/bazelbuild/rules_jvm_external/issues/178
        "io.kubernetes:client-java:4.0.0-beta1",
        # https://github.com/bazelbuild/rules_jvm_external/issues/199
        "com.google.ar.sceneform.ux:sceneform-ux:1.10.0",
        # https://github.com/bazelbuild/rules_jvm_external/issues/119#issuecomment-504704752
        "com.github.oshi:oshi-parent:3.4.0",
        "com.github.spinalhdl:spinalhdl-core_2.11:1.3.6",
        "com.github.spinalhdl:spinalhdl-lib_2.11:1.3.6",
        # https://github.com/bazelbuild/rules_jvm_external/issues/201
        "org.apache.kafka:kafka_2.11:2.1.1",
        "io.confluent:kafka-avro-serializer:5.0.1",
        # https://github.com/bazelbuild/rules_jvm_external/issues/309
        "io.quarkus.http:quarkus-http-servlet:3.0.0.Beta1",
        # https://github.com/bazelbuild/rules_jvm_external/issues/371
        "com.fasterxml.jackson:jackson-bom:2.9.10",
        "org.junit:junit-bom:5.3.1",
    ],
    generate_compat_repositories = True,
    maven_install_json = "//tests/custom_maven_install:regression_testing_install.json",
    override_targets = {
        "com.google.ar.sceneform:rendering": "@//tests/integration/override_targets:sceneform_rendering",
    },
    repositories = [
        "https://repo1.maven.org/maven2",
        "https://maven.google.com",
        "https://packages.confluent.io/maven/",
    ],
)

maven_install(
    name = "testonly_testing",
    artifacts = [
        maven.artifact(
            group = "com.google.guava",
            artifact = "guava",
            version = "27.0-jre",
        ),
        maven.artifact(
            group = "com.google.auto.value",
            artifact = "auto-value-annotations",
            version = "1.6.3",
            testonly = True,
        ),
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

load("@regression_testing//:defs.bzl", "pinned_maven_install")

pinned_maven_install()

load("@regression_testing//:compat.bzl", "compat_repositories")

compat_repositories()

maven_install(
    name = "policy_pinned_testing",
    artifacts = [
        # https://github.com/bazelbuild/rules_jvm_external/issues/107
        "com.google.cloud:google-cloud-storage:1.66.0",
        "com.google.guava:guava:25.0-android",
    ],
    maven_install_json = "//tests/custom_maven_install:policy_pinned_testing_install.json",
    repositories = [
        "https://repo1.maven.org/maven2",
        "https://maven.google.com",
    ],
    version_conflict_policy = "pinned",
)

load(
    "@policy_pinned_testing//:defs.bzl",
    _policy_pinned_maven_install = "pinned_maven_install",
)

_policy_pinned_maven_install()

maven_install(
    name = "strict_visibility_testing",
    artifacts = [
        # https://github.com/bazelbuild/rules_jvm_external/issues/94
        "org.apache.tomcat:tomcat-catalina:9.0.24",
        # https://github.com/bazelbuild/rules_jvm_external/issues/255
        maven.artifact(
            group = "org.eclipse.jetty",
            artifact = "jetty-http",
            version = "9.4.20.v20190813",
            classifier = "tests",
        ),
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
    strict_visibility = True,
)

maven_install(
    name = "maven_install_in_custom_location",
    artifacts = ["com.google.guava:guava:27.0-jre"],
    maven_install_json = "@rules_jvm_external//tests/custom_maven_install:maven_install.json",
    repositories = ["https://repo1.maven.org/maven2"],
)

load("@maven_install_in_custom_location//:defs.bzl", "pinned_maven_install")

pinned_maven_install()

# https://github.com/bazelbuild/rules_jvm_external/issues/311
maven_install(
    name = "duplicate_artifacts_test",
    artifacts = [
        "com.typesafe.play:play_2.11:2.5.19",
        "org.scalatestplus.play:scalatestplus-play_2.11:2.0.1",
    ],
    fetch_sources = True,
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
    use_unsafe_shared_cache = True,
    version_conflict_policy = "pinned",
)

maven_install(
    name = "jetify_all_test",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
        "com.android.support:appcompat-v7:28.0.0",
        "com.android.support:swiperefreshlayout:28.0.0",
    ],
    jetify = True,
    repositories = [
        "https://repo1.maven.org/maven2",
        "https://maven.google.com",
    ],
)

maven_install(
    name = "jetify_include_list_test",
    artifacts = [
        "com.google.guava:guava:27.0-jre",
        "com.android.support:appcompat-v7:28.0.0",
        "com.android.support:swiperefreshlayout:28.0.0",
    ],
    jetify = True,
    jetify_include_list = [
        "com.android.support:appcompat-v7",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
        "https://maven.google.com",
    ],
)

maven_install(
    name = "starlark_aar_import_test",
    artifacts = [
        "com.android.support:appcompat-v7:28.0.0",
    ],
    repositories = [
        "https://jcenter.bintray.com/",
        "https://maven.google.com",
    ],
    use_starlark_android_rules = True,
    # Not actually necessary since this is the default value, but useful for
    # testing.
    aar_import_bzl_label = "@build_bazel_rules_android//android:rules.bzl",
)

maven_install(
    name = "starlark_aar_import_with_jetify_test",
    artifacts = [
        "com.android.support:appcompat-v7:28.0.0",
    ],
    repositories = [
        "https://jcenter.bintray.com/",
        "https://maven.google.com",
    ],
    use_starlark_android_rules = True,
    # Not actually necessary since this is the default value, but useful for
    # testing.
    aar_import_bzl_label = "@build_bazel_rules_android//android:rules.bzl",
    jetify = True,
)

# for the above "starlark_aar_import_test" maven_install with
# use_starlark_android_rules = True
http_archive(
    name = "build_bazel_rules_android",
    urls = ["https://github.com/bazelbuild/rules_android/archive/v0.1.1.zip"],
    sha256 = "cd06d15dd8bb59926e4d65f9003bfc20f9da4b2519985c27e190cddc8b7a7806",
    strip_prefix = "rules_android-0.1.1",
)

# https://github.com/bazelbuild/rules_jvm_external/issues/351
maven_install(
    name = "json_artifacts_testing",
    artifacts = [
        "org.json:json:20190722",
        "io.quarkus:quarkus-maven-plugin:1.0.1.Final",
        "io.quarkus:quarkus-bom-descriptor-json:1.0.1.Final",
    ],
    fetch_sources = True,
    maven_install_json = "//tests/custom_maven_install:json_artifacts_testing_install.json",
    repositories = [
        "https://repo.maven.apache.org/maven2/",
        "https://repo.spring.io/plugins-release/",
    ],
)

# https://github.com/bazelbuild/rules_jvm_external/issues/433
maven_install(
    name = "version_interval_testing",
    artifacts = [
        "io.grpc:grpc-netty-shaded:1.29.0",
    ],
    repositories = [
        "https://repo1.maven.org/maven2",
    ],
)

load(
    "@json_artifacts_testing//:defs.bzl",
    _json_artifacts_testing_install = "pinned_maven_install",
)

_json_artifacts_testing_install()

RULES_KOTLIN_VERSION = "8ca948548159f288450516a09248dcfb9e957804"

http_archive(
    name = "io_bazel_rules_kotlin",
    sha256 = "22d7d3155b95f79e461451f565353bf0098d8a6ec2696a06edf9549bb15ab8ba",
    strip_prefix = "rules_kotlin-%s" % RULES_KOTLIN_VERSION,
    url = "https://github.com/bazelbuild/rules_kotlin/archive/%s.tar.gz" % RULES_KOTLIN_VERSION,
)

load("@io_bazel_rules_kotlin//kotlin:kotlin.bzl", "kotlin_repositories", "kt_register_toolchains")

kotlin_repositories()

kt_register_toolchains()

# End test dependencies

http_archive(
    name = "bazel_toolchains",
    sha256 = "89a053218639b1c5e3589a859bb310e0a402dedbe4ee369560e66026ae5ef1f2",
    strip_prefix = "bazel-toolchains-3.5.0",
    urls = [
        "https://github.com/bazelbuild/bazel-toolchains/releases/download/3.5.0/bazel-toolchains-3.5.0.tar.gz",
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-toolchains/archive/3.5.0.tar.gz",
    ],
)

load("@bazel_toolchains//rules:rbe_repo.bzl", "rbe_autoconfig")

# Creates a default toolchain config for RBE.
# Use this as is if you are using the rbe_ubuntu16_04 container,
# otherwise refer to RBE docs.
rbe_autoconfig(name = "buildkite_config")

load("//migration:maven_jar_migrator_deps.bzl", "maven_jar_migrator_repositories")

maven_jar_migrator_repositories()
