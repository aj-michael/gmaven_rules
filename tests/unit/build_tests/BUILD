load("@bazel_skylib//rules:build_test.bzl", "build_test")

# Regression tests for particular artifacts that revealed problems for this
# project.

build_test(
    name = "all_artifacts",
    targets = [
        "@regression_testing//:org_pantsbuild_jarjar",
        "@regression_testing//:com_github_fommil_netlib_all",
        "@regression_testing//:nz_ac_waikato_cms_weka_weka_stable",
        "@regression_testing//:org_eclipse_jetty_jetty_http_tests",
        "@regression_testing//:org_eclipse_jetty_orbit_javax_servlet",
        "@regression_testing//:org_apache_flink_flink_test_utils_2_12",
        "@regression_testing//:ch_epfl_scala_compiler_interface",
        "@regression_testing//:org_openjfx_javafx_base",
        "@regression_testing//:io_kubernetes_client_java",
        "@regression_testing//:io_quarkus_http_quarkus_http_servlet",
        "@regression_testing//:com_fasterxml_jackson_jackson_bom",
        "@regression_testing//:org_junit_junit_bom",
    ],
)

build_test(
    name = "compat_repository_alias",
    targets = [
        "@org_pantsbuild_jarjar//jar",
        "@nz_ac_waikato_cms_weka_weka_stable//jar",
        "@org_eclipse_jetty_jetty_http_tests//jar",
        "@org_apache_flink_flink_test_utils_2_12//jar",
    ],
)

build_test(
    name = "compat_repository_alias_jarless",
    targets = [
        "@org_pantsbuild_jarjar",
        "@nz_ac_waikato_cms_weka_weka_stable",
        "@org_eclipse_jetty_jetty_http_tests",
        "@org_apache_flink_flink_test_utils_2_12",
    ],
)

build_test(
    name = "version_conflict_policy_pinned",
    targets = [
        "@policy_pinned_testing//:com_google_guava_guava_25_0_android",
    ],
)

build_test(
    name = "unsafe_shared_cache_with_pinning",
    targets = [
        "@unsafe_shared_cache_with_pinning//:com_google_guava_guava",
    ],
)

build_test(
    name = "strict_version",
    targets = [
        "@strict_visibility_testing//:org_apache_tomcat_tomcat_catalina",
        "@strict_visibility_testing//:org_apache_tomcat_tomcat_catalina_9_0_24",
    ],
)

build_test(
    name = "strict_version_neg",
    tags = ["manual"],  # negative test case
    targets = [
        "@strict_visibility_testing//:org_apache_tomcat_tomcat_api",
    ],
)

build_test(
    name = "strict_version_classifier",
    targets = [
        "@strict_visibility_testing//:org_eclipse_jetty_jetty_http_tests",
    ],
)

build_test(
    name = "custom_maven_install_location",
    targets = [
        "@maven_install_in_custom_location//:com_google_guava_guava",
    ],
)

build_test(
    name = "ivy_repository",
    targets = [
        "@ivy_repo//:com_typesafe_sbt_sbt_native_packager"
    ],
)
