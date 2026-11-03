// DataGrip splits one data source across the shared `dataSources.xml` (driver, JDBC URL, group) and
// the machine-local `dataSources.local.xml` (user name, SSH, SSL); fragments of both merge by uuid.

use std::collections::HashMap;
use std::path::Path;

use roxmltree::Node;

use crate::apps::jetbrains::{expand, xml};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DataSource {
    pub uuid: String,
    pub name: String,
    pub driver_ref: String,
    pub jdbc_url: String,
    pub username: String,
    pub group_name: Option<String>,
    pub ssh: Option<SshReference>,
    pub ssl: Option<SslProperties>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Fragment {
    pub uuid: String,
    pub name: Option<String>,
    pub driver_ref: Option<String>,
    pub jdbc_url: Option<String>,
    pub username: Option<String>,
    pub group_name: Option<String>,
    pub ssh: Section<SshReference>,
    pub ssl: Section<SslProperties>,
}

// The local file can turn off a section the shared file turns on; a file without the section leaves it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum Section<T> {
    #[default]
    Absent,
    Disabled,
    Enabled(T),
}

impl<T: Clone> Section<T> {
    fn enabled(&self) -> Option<T> {
        match self {
            Self::Enabled(value) => Some(value.clone()),
            Self::Absent | Self::Disabled => None,
        }
    }
}

// Only an enabled `ssh-properties` becomes a reference.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SshReference {
    pub config_id: Option<String>,
    pub inline_host: Option<String>,
    pub inline_port: Option<u16>,
    pub inline_user: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SslProperties {
    pub mode: Option<String>,
    pub ca_cert_path: Option<String>,
    pub client_cert_path: Option<String>,
    pub client_key_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SshConfig {
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub auth_type: Option<String>,
    pub key_path: Option<String>,
}

impl Fragment {
    pub(crate) fn merge(&mut self, other: Self) {
        fn take<T>(target: &mut Option<T>, value: Option<T>) {
            if value.is_some() {
                *target = value;
            }
        }
        take(&mut self.name, other.name);
        take(&mut self.driver_ref, other.driver_ref);
        take(&mut self.jdbc_url, other.jdbc_url);
        take(&mut self.username, other.username);
        take(&mut self.group_name, other.group_name);
        if other.ssh != Section::Absent {
            self.ssh = other.ssh;
        }
        if other.ssl != Section::Absent {
            self.ssl = other.ssl;
        }
    }

    pub(crate) fn resolved(&self) -> Option<DataSource> {
        let driver_ref = self.driver_ref.clone().filter(|value| !value.is_empty())?;
        let jdbc_url = self.jdbc_url.clone().filter(|value| !value.is_empty())?;
        Some(DataSource {
            uuid: self.uuid.clone(),
            name: self.name.clone().unwrap_or_else(|| self.uuid.clone()),
            driver_ref,
            jdbc_url,
            username: self.username.clone().unwrap_or_default(),
            group_name: self.group_name.clone(),
            ssh: self.ssh.enabled(),
            ssl: self.ssl.enabled(),
        })
    }
}

pub(crate) fn parse_fragments(data: &[u8], home: &Path) -> Vec<Fragment> {
    let Some(document) = xml::document(data) else {
        return Vec::new();
    };
    xml::elements(&document, "data-source")
        .filter_map(|element| {
            let uuid = element.attribute("uuid")?;
            Some(parse_fragment(element, uuid, home))
        })
        .collect()
}

// A later `sshConfig` with the same id replaces an earlier one.
pub(crate) fn parse_ssh_configs(data: &[u8], home: &Path) -> HashMap<String, SshConfig> {
    let Some(document) = xml::document(data) else {
        return HashMap::new();
    };
    xml::elements(&document, "sshConfig")
        .filter_map(|element| {
            let id = element.attribute("id")?;
            let config = SshConfig {
                host: element.attribute("host").unwrap_or_default().to_owned(),
                port: element.attribute("port").and_then(|port| port.parse().ok()),
                username: element.attribute("username").unwrap_or_default().to_owned(),
                auth_type: element.attribute("authType").map(str::to_owned),
                key_path: element.attribute("keyPath").map(|path| expand(path, home)),
            };
            Some((id.to_owned(), config))
        })
        .collect()
}

fn parse_fragment(element: Node<'_, '_>, uuid: &str, home: &Path) -> Fragment {
    Fragment {
        uuid: uuid.to_owned(),
        name: non_empty(element.attribute("name").map(str::to_owned)),
        driver_ref: xml::child_text(element, "driver-ref"),
        jdbc_url: non_empty(xml::child_text(element, "jdbc-url")),
        username: non_empty(xml::child_text(element, "user-name")),
        group_name: non_empty(element.attribute("group-name").map(str::to_owned)),
        ssh: parse_ssh_reference(element),
        ssl: parse_ssl_properties(element, home),
    }
}

fn parse_ssh_reference(element: Node<'_, '_>) -> Section<SshReference> {
    let Some(ssh) = xml::child(element, "ssh-properties") else {
        return Section::Absent;
    };
    let enabled = xml::child_text(ssh, "enabled").or_else(|| ssh.attribute("enabled").map(str::to_owned));
    if enabled.as_deref() != Some("true") {
        return Section::Disabled;
    }
    let config_id = xml::child_text(ssh, "ssh-config-id").or_else(|| ssh.attribute("ssh-config-id").map(str::to_owned));
    Section::Enabled(SshReference {
        config_id: non_empty(config_id),
        inline_host: ssh.attribute("host").map(str::to_owned),
        inline_port: ssh.attribute("port").and_then(|port| port.parse().ok()),
        inline_user: ssh
            .attribute("user")
            .or_else(|| ssh.attribute("username"))
            .map(str::to_owned),
    })
}

fn parse_ssl_properties(element: Node<'_, '_>, home: &Path) -> Section<SslProperties> {
    let Some(ssl) = xml::child(element, "ssl-config") else {
        return Section::Absent;
    };
    if xml::child_text(ssl, "enabled").as_deref() != Some("true") {
        return Section::Disabled;
    }
    let cert_path = |name: &str| non_empty(xml::child_text(ssl, name)).map(|path| expand(&path, home));
    Section::Enabled(SslProperties {
        mode: xml::child_text(ssl, "mode"),
        ca_cert_path: cert_path("ca-cert"),
        client_cert_path: cert_path("client-cert"),
        client_key_path: cert_path("client-key"),
    })
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/home/me";

    fn fragments(xml: &str) -> Vec<Fragment> {
        parse_fragments(xml.as_bytes(), Path::new(HOME))
    }

    #[test]
    fn a_fragment_needs_a_uuid_and_resolves_only_with_a_driver_and_url() {
        let parsed = fragments(concat!(
            "<application><component>",
            "<data-source name=\"no uuid\"><driver-ref>mysql</driver-ref><jdbc-url>jdbc:mysql://h/a</jdbc-url></data-source>",
            "<data-source uuid=\"u1\"><driver-ref>mysql</driver-ref><jdbc-url> jdbc:mysql://h/a </jdbc-url></data-source>",
            "<data-source uuid=\"u2\" name=\"\"><jdbc-url>jdbc:mysql://h/a</jdbc-url></data-source>",
            "</component></application>"
        ));
        assert_eq!(parsed.len(), 2);
        let first = parsed[0].resolved().expect("a data source");
        assert_eq!(first.name, "u1");
        assert_eq!(first.jdbc_url, "jdbc:mysql://h/a");
        assert_eq!(parsed[1].resolved(), None);
    }

    #[test]
    fn a_later_fragment_replaces_only_the_fields_it_carries() {
        let mut shared = fragments(
            "<a><data-source uuid=\"u\" name=\"Shared\" group-name=\"G\"><driver-ref>pg</driver-ref><jdbc-url>jdbc:postgresql://h/db</jdbc-url></data-source></a>",
        )
        .remove(0);
        let local = fragments("<a><data-source uuid=\"u\"><user-name>me</user-name></data-source></a>").remove(0);
        shared.merge(local);
        let source = shared.resolved().expect("a data source");
        assert_eq!(source.name, "Shared");
        assert_eq!(source.group_name.as_deref(), Some("G"));
        assert_eq!(source.username, "me");
    }

    #[test]
    fn ssh_properties_read_from_children_or_attributes_and_only_when_enabled() {
        let parsed = fragments(concat!(
            "<a>",
            "<data-source uuid=\"1\"><ssh-properties><enabled>true</enabled><ssh-config-id>S</ssh-config-id></ssh-properties></data-source>",
            "<data-source uuid=\"2\"><ssh-properties enabled=\"true\" host=\"b\" port=\"2200\" username=\"u\" ssh-config-id=\"\"/></data-source>",
            "<data-source uuid=\"3\"><ssh-properties enabled=\"TRUE\" host=\"b\"/></data-source>",
            "</a>"
        ));
        let first = parsed[0].ssh.enabled().expect("ssh");
        assert_eq!(first.config_id.as_deref(), Some("S"));
        let second = parsed[1].ssh.enabled().expect("ssh");
        assert_eq!(second.config_id, None);
        assert_eq!(second.inline_host.as_deref(), Some("b"));
        assert_eq!(second.inline_port, Some(2200));
        assert_eq!(second.inline_user.as_deref(), Some("u"));
        assert_eq!(parsed[2].ssh, Section::Disabled);
    }

    #[test]
    fn a_section_the_local_file_disables_turns_off_the_shared_one_and_an_absent_one_keeps_it() {
        let shared = concat!(
            "<a>",
            "<data-source uuid=\"off\"><driver-ref>pg</driver-ref><jdbc-url>jdbc:postgresql://h/db</jdbc-url>",
            "<ssh-properties><enabled>true</enabled><ssh-config-id>S</ssh-config-id></ssh-properties>",
            "<ssl-config><enabled>true</enabled><mode>REQUIRE</mode></ssl-config></data-source>",
            "<data-source uuid=\"kept\"><driver-ref>pg</driver-ref><jdbc-url>jdbc:postgresql://h/db</jdbc-url>",
            "<ssh-properties><enabled>true</enabled><ssh-config-id>S</ssh-config-id></ssh-properties>",
            "<ssl-config><enabled>true</enabled><mode>REQUIRE</mode></ssl-config></data-source>",
            "</a>"
        );
        let local = concat!(
            "<a>",
            "<data-source uuid=\"off\"><ssh-properties><enabled>false</enabled><ssh-config-id>S</ssh-config-id>",
            "</ssh-properties><ssl-config><enabled>false</enabled></ssl-config></data-source>",
            "<data-source uuid=\"kept\"><user-name>me</user-name></data-source>",
            "</a>"
        );
        let mut merged = fragments(shared);
        for (fragment, local) in merged.iter_mut().zip(fragments(local)) {
            fragment.merge(local);
        }
        let off = merged[0].resolved().expect("a data source");
        assert_eq!((off.ssh, off.ssl), (None, None));
        let kept = merged[1].resolved().expect("a data source");
        assert_eq!(kept.ssh.and_then(|ssh| ssh.config_id).as_deref(), Some("S"));
        assert_eq!(kept.ssl.and_then(|ssl| ssl.mode).as_deref(), Some("REQUIRE"));
    }

    #[test]
    fn ssh_configs_are_keyed_by_id_and_expand_the_key_path() {
        let configs = parse_ssh_configs(
            b"<application><component name=\"SshConfigs\"><configs><sshConfig id=\"A\" host=\"h\" port=\"x\" keyPath=\"$USER_HOME$/.ssh/id\"/><sshConfig host=\"no id\"/></configs></component></application>",
            Path::new(HOME),
        );
        assert_eq!(configs.len(), 1);
        let config = &configs["A"];
        assert_eq!(config.port, None);
        assert_eq!(config.username, "");
        assert_eq!(config.key_path.as_deref(), Some("/home/me/.ssh/id"));
    }
}
