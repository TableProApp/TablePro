use std::time::Duration;

use testcontainers::core::IntoContainerPort;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, ImageExt};
use tokio::time::Instant;

use crate::container_file::with_files;
use crate::container_report::{container_state, log_tail};
use crate::{
    CassandraFlavour, CassandraTls, ContainerFile, ExecOutput, FixtureCredentials, FixtureError, PkiFile, TestNetwork,
    TestPki,
};

const KEYSPACE: &str = "tablepro";
const PASSWORD_USER: &str = "tablepro";
const LIMITED_USER: &str = "tablepro_limited";
// The superuser both images create on first start.
const ADMIN_USER: &str = "cassandra";
const ADMIN_PASSWORD: &str = "cassandra";
const DIR: &str = "/tablepro";
// A JVM that sizes its heap from the host's memory takes a quarter of
// it, more than a CI runner can give each container.
const CASSANDRA_HEAP: &str = "768M";
const CASSANDRA_NEW_HEAP: &str = "128M";
const SCYLLA_MEMORY: &str = "750M";
const READY_TIMEOUT: Duration = Duration::from_secs(240);
const READY_RETRY: Duration = Duration::from_secs(1);

/// Every top-level key the overrides file sets replaces the image's own,
/// whatever lines of the block followed it, and is then appended.
const CONFIGURE: &str = r#"#!/bin/sh
set -eu
yaml=$1
overrides=$2
for key in $(sed -n 's/^\([a-z_][a-z0-9_]*\):.*/\1/p' "$overrides"); do
  awk -v key="$key" '
    $0 ~ "^" key ":" { skip = 1; next }
    skip && /^[^ #]/ { skip = 0 }
    !skip { print }
  ' "$yaml" > "$yaml.tablepro"
  cat "$yaml.tablepro" > "$yaml"
done
rm -f "$yaml.tablepro"
cat "$overrides" >> "$yaml"
"#;

/// Cassandra 4.0 reads its TLS key only from a Java keystore, which no
/// tool in the image builds from a PEM key and its JRE cannot compile
/// Java, so the JRE's JavaScript engine builds it.
const KEYSTORES: &str = r#"var Files = Java.type("java.nio.file.Files");
var Paths = Java.type("java.nio.file.Paths");
var KeyStore = Java.type("java.security.KeyStore");
var KeyFactory = Java.type("java.security.KeyFactory");
var CertificateFactory = Java.type("java.security.cert.CertificateFactory");
var PKCS8EncodedKeySpec = Java.type("java.security.spec.PKCS8EncodedKeySpec");
var Base64 = Java.type("java.util.Base64");
var StandardCharsets = Java.type("java.nio.charset.StandardCharsets");
var dir = Paths.get(arguments[0]);
var password = new java.lang.String(arguments[1]).toCharArray();
function certificate(name) {
    var input = Files.newInputStream(dir.resolve(name));
    try {
        return CertificateFactory.getInstance("X.509").generateCertificate(input);
    } finally {
        input.close();
    }
}
function store(keystore, name) {
    var output = Files.newOutputStream(dir.resolve(name));
    try {
        keystore.store(output, password);
    } finally {
        output.close();
    }
}
var server = certificate("server.pem");
var ca = certificate("ca.pem");
var pem = new java.lang.String(Files.readAllBytes(dir.resolve("server.key")), StandardCharsets.US_ASCII);
var der = Base64.getMimeDecoder().decode(pem.replaceAll("-----[A-Z ]+-----", ""));
var key = KeyFactory.getInstance(server.getPublicKey().getAlgorithm()).generatePrivate(new PKCS8EncodedKeySpec(der));
var keystore = KeyStore.getInstance("PKCS12");
keystore.load(null, null);
keystore.setKeyEntry("server", key, password, Java.to([server, ca], "java.security.cert.Certificate[]"));
store(keystore, "keystore.p12");
var truststore = KeyStore.getInstance("PKCS12");
truststore.load(null, null);
truststore.setCertificateEntry("ca", ca);
store(truststore, "truststore.p12");
"#;

/// An Apache Cassandra or ScyllaDB node with password authentication, a
/// `tablepro` keyspace, user-defined functions and materialized views.
pub struct CassandraFixture {
    container: ContainerAsync<GenericImage>,
    flavour: CassandraFlavour,
    tls: CassandraTls,
    pki: TestPki,
    password: String,
    host: String,
    port: u16,
    network_alias: Option<String>,
    server_version: (u32, u32),
}

impl CassandraFixture {
    pub const CONTAINER_PORT: u16 = 9042;
    pub const NETWORK_ROLE: &'static str = "cassandra";
    pub const TLS_DIR: &'static str = "/tablepro/tls";

    pub async fn start(flavour: CassandraFlavour) -> Result<Self, FixtureError> {
        Self::start_with(flavour, CassandraTls::Off, None).await
    }

    pub async fn start_in(flavour: CassandraFlavour, network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::start_with(flavour, CassandraTls::Off, Some(network)).await
    }

    pub async fn start_with(
        flavour: CassandraFlavour,
        tls: CassandraTls,
        network: Option<&TestNetwork>,
    ) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let alias = network.map(|network| (network, network.container_name(Self::NETWORK_ROLE)));
        let fixture = Self::launch(flavour, tls, alias, None, pki, password).await?;
        fixture.cql(&fixture.setup_cql()).await?;
        Ok(fixture)
    }

    /// A second node of `seed`'s cluster, on its network, with its roles
    /// and keyspaces. Its port is published like the seed's, but a test
    /// that reaches the seed through its port reaches this one only at
    /// the address the cluster gives it on the network.
    pub async fn join(seed: &Self, network: &TestNetwork) -> Result<Self, FixtureError> {
        let reported = seed.exec(&["hostname", "-i"]).await?.stdout_text();
        let address = reported.split_whitespace().next().unwrap_or_default().to_owned();
        let alias = (network, network.container_name(&format!("{}-peer", Self::NETWORK_ROLE)));
        let pki = TestPki::generate()?;
        Self::launch(
            seed.flavour,
            CassandraTls::Off,
            Some(alias),
            Some(address),
            pki,
            seed.password.clone(),
        )
        .await
    }

    async fn launch(
        flavour: CassandraFlavour,
        tls: CassandraTls,
        network: Option<(&TestNetwork, String)>,
        seed: Option<String>,
        pki: TestPki,
        password: String,
    ) -> Result<Self, FixtureError> {
        let (release, server_version) = flavour.selected()?;
        let image = release
            .generic()
            .with_entrypoint(&format!("{DIR}/start.sh"))
            .with_exposed_port(Self::CONTAINER_PORT.tcp());
        let mut command = Self::command(flavour);
        if let (CassandraFlavour::Scylla, Some(seed)) = (flavour, &seed) {
            command.extend(["--seeds".to_owned(), seed.clone()]);
        }
        let mut request: ContainerRequest<GenericImage> = image.with_cmd(command);
        if flavour == CassandraFlavour::Cassandra {
            // A joining node waits out the ring delay to learn who owns
            // which tokens, so only the first node skips it.
            let options = match &seed {
                None => Self::fast_start_options(),
                Some(_) => "-Dcassandra.superuser_setup_delay_ms=0",
            };
            request = request
                .with_env_var("MAX_HEAP_SIZE", CASSANDRA_HEAP)
                .with_env_var("HEAP_NEWSIZE", CASSANDRA_NEW_HEAP)
                .with_env_var("JVM_EXTRA_OPTS", options);
            if let Some(seed) = &seed {
                request = request.with_env_var("CASSANDRA_SEEDS", seed.as_str());
            }
        }
        let network_alias = network.as_ref().map(|(_, alias)| alias.clone());
        if let Some((network, alias)) = &network {
            request = request.with_network(network.name()).with_container_name(alias.as_str());
        }
        let files = Self::files(flavour, server_version, tls, &pki, &password)?;
        let container = with_files(request, files).start().await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(Self::CONTAINER_PORT).await?;
        let fixture = Self {
            container,
            flavour,
            tls,
            pki,
            password,
            host,
            port,
            network_alias,
            server_version,
        };
        fixture.wait_until_ready().await?;
        Ok(fixture)
    }

    /// The image's own entrypoint and arguments, which the start script
    /// runs once the configuration is in place.
    pub fn command(flavour: CassandraFlavour) -> Vec<String> {
        let command: &[&str] = match flavour {
            CassandraFlavour::Cassandra => &["docker-entrypoint.sh", "cassandra", "-f"],
            // A Lua function stops at ten milliseconds unless told
            // otherwise, and the suites need one that runs until dropped.
            CassandraFlavour::Scylla => &[
                "/docker-entrypoint.py",
                "--smp",
                "1",
                "--memory",
                SCYLLA_MEMORY,
                "--overprovisioned",
                "1",
                "--developer-mode",
                "1",
                "--authenticator",
                "PasswordAuthenticator",
                "--authorizer",
                "CassandraAuthorizer",
                "--enable-user-defined-functions",
                "true",
                "--experimental-features",
                "udf",
                "--user-defined-function-time-limit-ms",
                "3600000",
                "--batch-size-warn-threshold-in-kb",
                "10240",
                "--batch-size-fail-threshold-in-kb",
                "10240",
            ],
        };
        command.iter().map(|&part| part.to_owned()).collect()
    }

    // A single node has no gossip to settle and no ring to wait for, and
    // the superuser the readiness check logs in as is created at once.
    fn fast_start_options() -> &'static str {
        "-Dcassandra.skip_wait_for_gossip_to_settle=0 -Dcassandra.ring_delay_ms=0 \
         -Dcassandra.superuser_setup_delay_ms=0"
    }

    pub fn files(
        flavour: CassandraFlavour,
        server_version: (u32, u32),
        tls: CassandraTls,
        pki: &TestPki,
        password: &str,
    ) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls_dir = Self::TLS_DIR;
        let mut start = format!(
            "#!/bin/sh\nset -eu\n{DIR}/configure.sh {} {DIR}/overrides.yaml\n",
            flavour.configuration_file()
        );
        let mut files = vec![
            ContainerFile::executable(format!("{DIR}/configure.sh"), CONFIGURE),
            ContainerFile::readable(
                format!("{DIR}/overrides.yaml"),
                Self::overrides(flavour, server_version, tls, password),
            ),
            // ScyllaDB's image runs an exec as its own user, not as root.
            ContainerFile::readable(format!("{DIR}/cqlshrc"), Self::cqlshrc()),
            ContainerFile::readable(format!("{tls_dir}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(format!("{tls_dir}/server.pem"), pki.read(PkiFile::ServerCertificate)?),
            ContainerFile::readable(format!("{tls_dir}/server.key"), pki.read(PkiFile::ServerKey)?),
            ContainerFile::readable(format!("{tls_dir}/client.pem"), pki.read(PkiFile::ClientCertificate)?),
            ContainerFile::readable(format!("{tls_dir}/client.key"), pki.read(PkiFile::ClientKey)?),
        ];
        match (flavour, tls.is_on(), Self::reads_pem(server_version)) {
            (CassandraFlavour::Cassandra, true, true) => {
                let mut combined = pki.read(PkiFile::ServerKey)?;
                combined.extend(pki.read(PkiFile::ServerCertificate)?);
                combined.extend(pki.read(PkiFile::Ca)?);
                files.push(ContainerFile::readable(
                    format!("{tls_dir}/server-combined.pem"),
                    combined,
                ));
            }
            (CassandraFlavour::Cassandra, true, false) => {
                files.push(ContainerFile::readable(format!("{DIR}/keystores.js"), KEYSTORES));
                start.push_str(&format!(
                    "jjs {DIR}/keystores.js -- {tls_dir} {password}\n\
                     chmod 0644 {tls_dir}/keystore.p12 {tls_dir}/truststore.p12\n"
                ));
            }
            _ => {}
        }
        start.push_str("exec \"$@\"\n");
        files.push(ContainerFile::executable(format!("{DIR}/start.sh"), start));
        Ok(files)
    }

    /// What the fixture changes in the image's configuration file, in the
    /// spelling the release reads: Cassandra 4.1 renamed most keys.
    pub fn overrides(
        flavour: CassandraFlavour,
        server_version: (u32, u32),
        tls: CassandraTls,
        password: &str,
    ) -> String {
        let mut overrides = String::new();
        if flavour == CassandraFlavour::Cassandra {
            overrides.push_str(
                "authenticator: PasswordAuthenticator\n\
                 authorizer: CassandraAuthorizer\n\
                 allow_insecure_udfs: true\n",
            );
            // In the request thread, a function runs until its caller
            // goes, which is the statement that never ends the suites
            // need; in its own thread it stops after 1.5 seconds.
            overrides.push_str(match server_version >= (4, 1) {
                true => {
                    "user_defined_functions_enabled: true\n\
                     user_defined_functions_threads_enabled: false\n\
                     materialized_views_enabled: true\n\
                     batch_size_warn_threshold: 10MiB\n\
                     batch_size_fail_threshold: 10MiB\n"
                }
                false => {
                    "enable_user_defined_functions: true\n\
                     enable_user_defined_functions_threads: false\n\
                     enable_materialized_views: true\n\
                     batch_size_warn_threshold_in_kb: 10240\n\
                     batch_size_fail_threshold_in_kb: 10240\n"
                }
            });
        }
        if !tls.is_on() {
            return overrides;
        }
        let tls_dir = Self::TLS_DIR;
        let require_client_auth = tls == CassandraTls::ClientCertificate;
        match flavour {
            CassandraFlavour::Cassandra if Self::reads_pem(server_version) => overrides.push_str(&format!(
                "client_encryption_options:\n  \
                 enabled: true\n  \
                 optional: false\n  \
                 ssl_context_factory:\n    \
                 class_name: org.apache.cassandra.security.PEMBasedSslContextFactory\n  \
                 keystore: {tls_dir}/server-combined.pem\n  \
                 truststore: {tls_dir}/ca.pem\n  \
                 require_client_auth: {require_client_auth}\n"
            )),
            CassandraFlavour::Cassandra => overrides.push_str(&format!(
                "client_encryption_options:\n  \
                 enabled: true\n  \
                 optional: false\n  \
                 keystore: {tls_dir}/keystore.p12\n  \
                 keystore_password: {password}\n  \
                 store_type: PKCS12\n  \
                 require_client_auth: {require_client_auth}\n  \
                 truststore: {tls_dir}/truststore.p12\n  \
                 truststore_password: {password}\n"
            )),
            CassandraFlavour::Scylla => overrides.push_str(&format!(
                "client_encryption_options:\n  \
                 enabled: true\n  \
                 certificate: {tls_dir}/server.pem\n  \
                 keyfile: {tls_dir}/server.key\n  \
                 truststore: {tls_dir}/ca.pem\n  \
                 require_client_auth: {require_client_auth}\n"
            )),
        }
        overrides
    }

    // Cassandra 4.1 added a context factory that reads PEM files.
    fn reads_pem(server_version: (u32, u32)) -> bool {
        server_version >= (4, 1)
    }

    // The fixture's own cqlsh trusts whatever the node serves; the tests
    // check the certificate, not the fixture.
    fn cqlshrc() -> String {
        let tls_dir = Self::TLS_DIR;
        format!(
            "[authentication]\nusername = {ADMIN_USER}\npassword = {ADMIN_PASSWORD}\n\
             [ssl]\nvalidate = false\nuserkey = {tls_dir}/client.key\nusercert = {tls_dir}/client.pem\n"
        )
    }

    /// The roles and the keyspace the tests use. ScyllaDB 2025.1 keeps a
    /// keyspace with tablets, its default, from having the secondary
    /// indexes, views and lightweight transactions the suites create.
    pub fn setup_cql(&self) -> String {
        let password = &self.password;
        let client = TestPki::CLIENT_COMMON_NAME;
        let keyspace = match (self.flavour, self.server_version < (2026, 1)) {
            (CassandraFlavour::Cassandra, _) => {
                format!(
                    "CREATE KEYSPACE {KEYSPACE} WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}}"
                )
            }
            (CassandraFlavour::Scylla, true) => format!(
                "CREATE KEYSPACE {KEYSPACE} WITH replication = \
                 {{'class': 'NetworkTopologyStrategy', 'replication_factor': 1}} AND tablets = {{'enabled': false}}"
            ),
            (CassandraFlavour::Scylla, false) => format!(
                "CREATE KEYSPACE {KEYSPACE} WITH replication = \
                 {{'class': 'NetworkTopologyStrategy', 'replication_factor': 1}}"
            ),
        };
        format!(
            "CREATE ROLE {PASSWORD_USER} WITH PASSWORD = '{password}' AND LOGIN = true AND SUPERUSER = true;\n\
             CREATE ROLE {LIMITED_USER} WITH PASSWORD = '{password}' AND LOGIN = true;\n\
             CREATE ROLE {client} WITH PASSWORD = '{password}' AND LOGIN = true;\n\
             {keyspace};\n\
             GRANT SELECT ON KEYSPACE {KEYSPACE} TO {LIMITED_USER};\n"
        )
    }

    pub fn flavour(&self) -> CassandraFlavour {
        self.flavour
    }

    pub fn tls(&self) -> CassandraTls {
        self.tls
    }

    /// The major and minor version of the release the fixture started.
    pub fn server_version(&self) -> (u32, u32) {
        self.server_version
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn keyspace(&self) -> &str {
        KEYSPACE
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    /// A superuser.
    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    /// A role that may only read the `tablepro` keyspace.
    pub fn limited_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(LIMITED_USER, &self.password)
    }

    /// The role for the client certificate. Both engines still ask it
    /// for its password; the certificate only gets it through TLS.
    pub fn certificate_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(TestPki::CLIENT_COMMON_NAME, &self.password)
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }

    /// Run `statements` through the node's own cqlsh as the image's
    /// superuser, failing with what cqlsh printed unless all of them
    /// succeed.
    pub async fn cql(&self, statements: &str) -> Result<ExecOutput, FixtureError> {
        let output = self.cqlsh(statements).await?;
        // cqlsh -e exits 0 after a failed statement in some releases, and
        // reports it on stderr in all of them.
        let stderr = output.stderr_text();
        let failed = stderr
            .lines()
            .any(|line| line.contains("Error") || line.contains("Exception"));
        if !output.succeeded() || failed {
            return Err(FixtureError::Cql {
                service: self.flavour.service(),
                statements: statements.to_owned(),
                output: format!("{}{}", output.stdout_text(), stderr),
            });
        }
        Ok(output)
    }

    // cqlsh -e takes one statement; a file takes a script. ScyllaDB
    // listens on the container's address only.
    async fn cqlsh(&self, statements: &str) -> Result<ExecOutput, FixtureError> {
        let ssl = if self.tls.is_on() { " --ssl" } else { "" };
        let script = format!(
            "file=$(mktemp) && printf '%s\\n' \"$1\" > \"$file\" && \
             cqlsh --cqlshrc {DIR}/cqlshrc{ssl} -f \"$file\" \"$(hostname -i | cut -d' ' -f1)\" 9042; \
             status=$?; rm -f \"$file\"; exit $status"
        );
        // A file's last statement runs only once a semicolon ends it.
        let statements = match statements.trim_end().ends_with(';') {
            true => statements.to_owned(),
            false => format!("{};", statements.trim_end()),
        };
        self.exec(&["sh", "-c", &script, "cqlsh", &statements]).await
    }

    async fn wait_until_ready(&self) -> Result<(), FixtureError> {
        let deadline = Instant::now() + READY_TIMEOUT;
        loop {
            let last_reply = match self.cqlsh("SELECT release_version FROM system.local").await {
                Ok(output) if output.succeeded() => return Ok(()),
                Ok(output) => last_line(&format!("{}{}", output.stdout_text(), output.stderr_text())),
                Err(error) => error.to_string(),
            };
            if !self.container.is_running().await? {
                return Err(self.not_ready("the container exited".to_owned(), last_reply).await);
            }
            if Instant::now() >= deadline {
                let reason = format!("no login within {} seconds", READY_TIMEOUT.as_secs());
                return Err(self.not_ready(reason, last_reply).await);
            }
            tokio::time::sleep(READY_RETRY).await;
        }
    }

    async fn not_ready(&self, reason: String, last_reply: String) -> FixtureError {
        FixtureError::ContainerNotReady {
            service: self.flavour.service(),
            reason,
            last_reply,
            state: container_state(&self.container).await,
            logs: log_tail(&self.container).await,
        }
    }
}

fn last_line(text: &str) -> String {
    text.lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no output")
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file<'a>(files: &'a [ContainerFile], target: &str) -> Option<&'a ContainerFile> {
        files.iter().find(|file| file.target() == target)
    }

    fn text(file: &ContainerFile) -> String {
        String::from_utf8_lossy(file.contents()).into_owned()
    }

    #[test]
    fn each_release_gets_the_key_spelling_it_reads() {
        let old = CassandraFixture::overrides(CassandraFlavour::Cassandra, (4, 0), CassandraTls::Off, "x");
        let new = CassandraFixture::overrides(CassandraFlavour::Cassandra, (5, 0), CassandraTls::Off, "x");

        assert!(old.contains("enable_user_defined_functions_threads: false\n"), "{old}");
        assert!(old.contains("batch_size_fail_threshold_in_kb: 10240\n"), "{old}");
        assert!(!old.contains("user_defined_functions_enabled"), "{old}");
        assert!(new.contains("user_defined_functions_threads_enabled: false\n"), "{new}");
        assert!(new.contains("batch_size_fail_threshold: 10MiB\n"), "{new}");
        assert!(!new.contains("_in_kb"), "{new}");
        for overrides in [&old, &new] {
            assert!(
                overrides.starts_with("authenticator: PasswordAuthenticator\n"),
                "{overrides}"
            );
            assert!(!overrides.contains("client_encryption_options"), "{overrides}");
        }
    }

    #[test]
    fn scylla_takes_its_settings_as_arguments_and_only_tls_from_the_file() {
        assert_eq!(
            CassandraFixture::overrides(CassandraFlavour::Scylla, (2026, 1), CassandraTls::Off, "x"),
            ""
        );
        let command = CassandraFixture::command(CassandraFlavour::Scylla);
        assert_eq!(command[0], "/docker-entrypoint.py");
        assert!(
            command
                .windows(2)
                .any(|pair| pair == ["--authenticator", "PasswordAuthenticator"])
        );

        let tls = CassandraFixture::overrides(CassandraFlavour::Scylla, (2026, 1), CassandraTls::Required, "x");
        assert!(
            tls.starts_with("client_encryption_options:\n  enabled: true\n"),
            "{tls}"
        );
        assert!(tls.contains("  require_client_auth: false\n"), "{tls}");
    }

    #[test]
    fn a_client_certificate_server_asks_every_client_for_one() {
        for flavour in CassandraFlavour::ALL {
            let overrides = CassandraFixture::overrides(flavour, (5, 0), CassandraTls::ClientCertificate, "x");
            assert!(
                overrides.contains("  require_client_auth: true\n"),
                "{flavour:?}: {overrides}"
            );
        }
        let cassandra = CassandraFixture::overrides(CassandraFlavour::Cassandra, (4, 0), CassandraTls::Required, "pw");
        assert!(cassandra.contains("  optional: false\n"), "{cassandra}");
        assert!(cassandra.contains("  keystore_password: pw\n"), "{cassandra}");
    }

    #[test]
    fn only_cassandra_4_0_builds_keystores_and_later_releases_read_pem() {
        let pki = TestPki::generate().unwrap();
        let start = |flavour, version, tls| {
            let files = CassandraFixture::files(flavour, version, tls, &pki, "pw").unwrap();
            let start = file(&files, "/tablepro/start.sh").map(text).unwrap();
            let keystores = file(&files, "/tablepro/keystores.js").is_some();
            let combined = file(&files, "/tablepro/tls/server-combined.pem").map(text);
            (start, keystores, combined)
        };

        let (script, keystores, combined) = start(CassandraFlavour::Cassandra, (4, 0), CassandraTls::Required);
        assert!(keystores && combined.is_none());
        assert!(
            script.contains("jjs /tablepro/keystores.js -- /tablepro/tls pw\n"),
            "{script}"
        );
        assert!(script.ends_with("exec \"$@\"\n"), "{script}");

        let (script, keystores, combined) = start(CassandraFlavour::Cassandra, (5, 0), CassandraTls::Required);
        assert!(!keystores && !script.contains("jjs"), "{script}");
        let combined = combined.unwrap();
        assert!(combined.starts_with("-----BEGIN PRIVATE KEY-----"), "{combined}");
        assert_eq!(combined.matches("-----BEGIN CERTIFICATE-----").count(), 2);
        let pem = CassandraFixture::overrides(CassandraFlavour::Cassandra, (5, 0), CassandraTls::Required, "pw");
        assert!(
            pem.contains("class_name: org.apache.cassandra.security.PEMBasedSslContextFactory\n"),
            "{pem}"
        );

        for (flavour, version, tls) in [
            (CassandraFlavour::Cassandra, (4, 0), CassandraTls::Off),
            (CassandraFlavour::Scylla, (2025, 1), CassandraTls::Required),
        ] {
            let (script, keystores, combined) = start(flavour, version, tls);
            assert!(!keystores && combined.is_none(), "{flavour:?} {tls:?}");
            assert!(!script.contains("jjs"), "{script}");
        }
    }

    #[test]
    fn the_scripts_are_executable_and_the_rest_readable() {
        let pki = TestPki::generate().unwrap();
        let files =
            CassandraFixture::files(CassandraFlavour::Cassandra, (5, 0), CassandraTls::Required, &pki, "pw").unwrap();

        for file in &files {
            let expected = match file.target().ends_with(".sh") {
                true => ContainerFile::EXECUTABLE,
                false => ContainerFile::READABLE,
            };
            assert_eq!(file.mode(), expected, "{}", file.target());
        }
    }
}
