import java.io.BufferedReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.MalformedURLException;
import java.net.URL;
import java.nio.channels.Channels;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * A command line tool for generating Bazel workspace rules for all JARs and AARs on
 * https://maven.google.com.
 */
public class GMavenToBazel {

  private GMavenToBazel() {}

  private static final String MASTER_INDEX_URL =
      "https://dl.google.com/dl/android/maven2/master-index.xml";
  private static final String GROUP_INDEX_TEMPLATE_URL =
      "https://dl.google.com/dl/android/maven2/%s/group-index.xml";
  private static final String POM_TEMPLATE_URL =
      "https://dl.google.com/dl/android/maven2/%s/%s/%s/%s-%s.pom";
  private static final String SHA1_TEMPLATE_URL =
      "https://dl.google.com/dl/android/maven2/%s/%s/%s/%s-%s.%s.sha1";
  private static final String OUTPUT_FILE = "gmaven.bzl";
  private static final DocumentBuilderFactory documentBuilderFactory =
      DocumentBuilderFactory.newInstance();
  private static final Map<String, String> PACKAGING_TO_RULE = new HashMap<>();

  static {
    PACKAGING_TO_RULE.put("jar", "maven_jar");
    PACKAGING_TO_RULE.put("aar", "maven_aar");
  }

  public static void main(String[] args) throws Exception {
    Document masterIndex = parseUrl(new URL(MASTER_INDEX_URL));
    List<String> groupIds = getGroupdIds(masterIndex);
    Map<String, String> repositoryNameToRuleType = new HashMap<>();
    Map<String, String> repositoryNameToTargetName = new HashMap<>();
    Map<String, String> repositoryNameToArtifactSha = new HashMap<>();
    Map<String, String> repositoryNameToArtifactString = new HashMap<>();
    Map<String, Set<String>> repositoryNameToRepositoryNameDeps = new HashMap<>();
    for (String groupId : groupIds) {
      Map<String, Set<String>> artifactsToVersions = getArtifactsToVersions(groupId);
      for (String artifactId : artifactsToVersions.keySet()) {
        for (String version : artifactsToVersions.get(artifactId)) {
          Document pom = parseUrl(getPomUrl(groupId, artifactId, version));
          Element project = (Element) pom.getElementsByTagName("project").item(0);
          String packaging = getPackaging(project);
          if (!PACKAGING_TO_RULE.containsKey(packaging)) {
            // We don't support APK packaging yet.
            continue;
          }
          String repositoryName;
          String sha1 = getArtifactSha1(getSha1Url(groupId, artifactId, version, packaging));
          repositoryName = getRepositoryName(groupId, artifactId, version);
          repositoryNameToRuleType.put(repositoryName, PACKAGING_TO_RULE.get(packaging));
          repositoryNameToTargetName.put(
              repositoryName, getTargetName(groupId, artifactId, version, packaging));
          repositoryNameToArtifactString.put(
              repositoryName, getArtifactString(groupId, artifactId, version));
          repositoryNameToRepositoryNameDeps.put(repositoryName, getDependencyRepositoryNames(pom));
          if (sha1 != null) {
            repositoryNameToArtifactSha.put(repositoryName, sha1);
          }
        }
      }
    }


    PrintWriter bzlWriter = new PrintWriter(new FileWriter(OUTPUT_FILE));
    bzlWriter.println(
        "load('@bazel_tools//tools/build_defs/repo:maven_rules.bzl', 'maven_jar', 'maven_aar')");
    bzlWriter.println("def gmaven_rules(maven_settings_file =  '@gmaven_rules//:settings.xml'):");
    for (String repositoryName : repositoryNameToRuleType.keySet()) {
      String ruleType = repositoryNameToRuleType.get(repositoryName);
      String artifactString = repositoryNameToArtifactString.get(repositoryName);
      String sha1 = repositoryNameToArtifactSha.get(repositoryName);
      bzlWriter.println();
      bzlWriter.println(String.format("  %s(", ruleType));
      bzlWriter.println(String.format("      name = '%s',", repositoryName));
      bzlWriter.println(String.format("      artifact = '%s',", artifactString));
      if (sha1 != null) {
        bzlWriter.println(String.format("      sha1 = '%s',", sha1));
      }
      bzlWriter.println("      settings = maven_settings_file,");
      bzlWriter.println("      deps = [");
      for (String repositoryNameDep : repositoryNameToRepositoryNameDeps.get(repositoryName)) {
        String targetNameDep = repositoryNameToTargetName.get(repositoryNameDep);
        if (targetNameDep == null) {
          // our princess is in another castle!
          bzlWriter.println(String.format("        # GMaven does not have %s" , repositoryNameDep));
        } else {
          bzlWriter.println(
              String.format("        '%s',", repositoryNameToTargetName.get(repositoryNameDep)));
        }
      }
      bzlWriter.println("      ],");
      bzlWriter.println("    )");
    }

    bzlWriter.close();
  }

  private static String getArtifactSha1(URL sha1Url) throws IOException {
    String sha1 = null;
    try (InputStream sha1Stream = sha1Url.openStream()) {
      sha1 = new BufferedReader(new InputStreamReader(sha1Stream)).readLine().trim();
    } catch (java.io.FileNotFoundException e) {
    }
    return sha1;
  }

  private static Document parseUrl(URL url) throws Exception {
    return documentBuilderFactory.newDocumentBuilder().parse(url.openStream());
  }

  private static List<String> getGroupdIds(Document masterIndex) {
    List<String> groupIds = new ArrayList<>();
    NodeList groupIdNodes = masterIndex.getDocumentElement().getChildNodes();
    for (int index = 1; index < groupIdNodes.getLength(); index += 2) {
      groupIds.add(groupIdNodes.item(index).getNodeName());
    }
    return groupIds;
  }

  private static Map<String, Set<String>> getArtifactsToVersions(String groupId)
      throws Exception {
    Document groupIndex = parseUrl(getGroupIndexUrl(groupId));
    Map<String, Set<String>> result = new HashMap<>();
    NodeList artifactNodes = groupIndex.getDocumentElement().getChildNodes();
    for (int index = 1; index < artifactNodes.getLength(); index += 2) {
      Node artifactNode = artifactNodes.item(index);
      Node versionsNode = artifactNode.getAttributes().getNamedItem("versions");
      result.put(
          artifactNode.getNodeName(),
          new HashSet<>(Arrays.asList(versionsNode.getNodeValue().split(","))));
    }
    return result;
  }

  private static URL getGroupIndexUrl(String groupId) throws MalformedURLException {
    return new URL(String.format(GROUP_INDEX_TEMPLATE_URL, groupId.replaceAll("\\.", "/")));
  }

  private static URL getPomUrl(String groupId, String artifactId, String version) throws Exception {
    return new URL(
        String.format(
            POM_TEMPLATE_URL,
            groupId.replaceAll("\\.", "/"),
            artifactId,
            version,
            artifactId,
            version));
  }
  private static URL getSha1Url(String groupId, String artifactId, String version, String packaging) throws Exception {
    return new URL(
        String.format(
            SHA1_TEMPLATE_URL,
            groupId.replaceAll("\\.", "/"),
            artifactId,
            version,
            artifactId,
            version,
            packaging));
  }

  private static String getPackaging(Element element) throws Exception {
    NodeList packaging = element.getElementsByTagName("packaging");
    return packaging.getLength() > 0 ? packaging.item(0).getTextContent() : "jar";
  }

  private static Set<String> getDependencyRepositoryNames(Document pom) throws Exception {
    NodeList dependencies = pom.getElementsByTagName("dependency");
    Set<String> result = new HashSet<>();
    for (int index = 0; index < dependencies.getLength(); index++) {
      Element dependency = (Element) dependencies.item(index);
      String groupId = dependency.getElementsByTagName("groupId").item(0).getTextContent();
      String artifactId = dependency.getElementsByTagName("artifactId").item(0).getTextContent();
      String version = getDependencyVersion(dependency);
      if (dependency.getElementsByTagName("scope").item(0) != null) {
        String scope = dependency.getElementsByTagName("scope").item(0).getTextContent();
        if (scope.equals("test")) {
          continue;
        }
      }
      result.add(getRepositoryName(groupId, artifactId, version));
    }
    return result;
  }

  private static String getArtifactString(String groupId, String artifactId, String version) {
    return String.format("%s:%s:%s", groupId, artifactId, version);
  }

  private static String getRepositoryName(String groupId, String artifactId, String version) {
    return escape(String.format("%s_%s_%s", groupId, artifactId, version));
  }

  private static String getTargetName(
      String groupId, String artifactId, String version, String packaging) {
    return String.format("@%s//%s", getRepositoryName(groupId, artifactId, version), packaging);
  }

  private static String escape(String string) {
    return string.replaceAll("[.-]", "_");
  }

  // Versions can be of the form [A], [A,B], [A,] or [,A]. We just pick one.
  private static String getDependencyVersion(Element element) {
    String raw = element.getElementsByTagName("version").item(0).getTextContent();
    raw = raw.replaceAll("\\[|]", "");
    return raw.split(",")[0];
  }
}
