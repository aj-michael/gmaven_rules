load(":has_maven_deps.bzl", "MavenInfo", "has_maven_deps")

_PLAIN_DEP = """        <dependency>
            <groupId>{0}</groupId>
            <artifactId>{1}</artifactId>
            <version>{2}</version>
        </dependency>"""

_TYPED_DEP = """        <dependency>
            <groupId>{0}</groupId>
            <artifactId>{1}</artifactId>
            <version>{2}</version>
            <type>{3}</type>
        </dependency>"""

def _explode_coordinates(coords):
    """Takes a maven coordinate and explodes it into a tuple of
    (groupId, artifactId, version, type)
    """
    if not coords:
        return None

    parts = coords.split(":")
    if len(parts) == 3:
        return (parts[0], parts[1], parts[2], "jar")
    if len(parts) == 4:
        # Assume a buildr coordinate: groupId:artifactId:type:version
        return (parts[0], parts[1], parts[3], parts[2])
    if len(parts) == 5:
        # Assume groupId:artifactId:type:classifier:version
        return (parts[0], parts[1], parts[4], parts[2], parts[3])

    fail("Unparsed: %s" % coords)

def _pom_file_impl(ctx):
    # Ensure the target has coordinates
    if not ctx.attr.target[MavenInfo].coordinates:
        fail("pom_file target must have maven coordinates.")

    info = ctx.attr.target[MavenInfo]

    coordinates = _explode_coordinates(info.coordinates)
    substitutions = {
        "{groupId}": coordinates[0],
        "{artifactId}": coordinates[1],
        "{version}": coordinates[2],
        "{type}": coordinates[3],
    }

    deps = []
    for dep in sorted(info.maven_deps.to_list()):
        exploded = _explode_coordinates(dep)
        if (exploded[3] == "jar"):
            template = _PLAIN_DEP
        else:
            template = _TYPED_DEP
        deps.append(template.format(*exploded))
    substitutions.update({"{dependencies}": "\n".join(deps)})

    out = ctx.actions.declare_file("%s.xml" % ctx.label.name)
    ctx.actions.expand_template(
        template = ctx.file.pom_template,
        output = out,
        substitutions = substitutions,
    )

    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(
            pom = depset([out]),
        ),
    ]

pom_file = rule(
    _pom_file_impl,
    doc = """Generate a pom.xml file that lists first-order maven dependencies.

The following substitutions are performed on the template file:

  {groupId}: Replaced with the maven coordinates group ID.
  {artifactId}: Replaced with the maven coordinates artifact ID.
  {version}: Replaced by the maven coordinates version.
  {type}: Replaced by the maven coordintes type, if present (defaults to "jar")
  {dependencies}: Replaced by a list of maven dependencies directly relied upon
    by java_library targets within the artifact.
""",
    attrs = {
        "pom_template": attr.label(
            doc = "Template file to use for the pom.xml",
            default = "//private/templates:pom.tpl",
            allow_single_file = True,
        ),
        "target": attr.label(
            doc = "The rule to base the pom file on. Must be a java_library and have a maven_coordinate tag.",
            mandatory = True,
            providers = [
                [JavaInfo],
            ],
            aspects = [
                has_maven_deps,
            ],
        ),
    },
)
