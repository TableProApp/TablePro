use std::collections::{BTreeSet, HashMap};

use serde::Deserialize;

use super::{HTTP_TUNNEL, PROXY, PROXY_COMMAND, SSH_TUNNEL};

// The fields of DBX's `ConnectionConfig` an import reads. A field this does not name is ignored, and
// one left out takes DBX's own default.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct Config {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) db_type: String,
    pub(super) driver_profile: Option<String>,
    pub(super) url_params: Option<String>,
    pub(super) host: String,
    pub(super) port: u16,
    pub(super) username: String,
    pub(super) database: Option<String>,
    pub(super) color: Option<String>,
    pub(super) ssl: bool,
    pub(super) ca_cert_path: String,
    pub(super) client_cert_path: String,
    pub(super) client_key_path: String,
    pub(super) transport_layers: Vec<Layer>,
    pub(super) init_script: Option<String>,
    pub(super) attached_databases: Vec<serde_json::Value>,
    pub(super) connection_string: Option<String>,
    // A connection saved before `transport_layers` existed, which DBX turns into layers as it reads it.
    ssh_enabled: Option<bool>,
    ssh_tunnels: Option<Vec<SshLayer>>,
    ssh_host: Option<String>,
    ssh_port: Option<u16>,
    ssh_user: Option<String>,
    ssh_key_path: Option<String>,
    proxy_enabled: Option<bool>,
    proxy_host: Option<String>,
}

// The last layer is the hop next to the database.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum Layer {
    Ssh(SshLayer),
    Proxy(OtherLayer),
    HttpTunnel(OtherLayer),
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub(super) struct SshLayer {
    pub(super) enabled: bool,
    pub(super) host: String,
    pub(super) port: u16,
    pub(super) user: String,
    pub(super) key_path: String,
    pub(super) use_ssh_agent: bool,
    pub(super) auth_method: String,
    pub(super) proxy_command: String,
    pub(super) profile_id: String,
}

impl Default for SshLayer {
    fn default() -> Self {
        Self {
            enabled: true,
            host: String::new(),
            port: 22,
            user: String::new(),
            key_path: String::new(),
            use_ssh_agent: false,
            auth_method: String::new(),
            proxy_command: String::new(),
            profile_id: String::new(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub(super) struct OtherLayer {
    enabled: bool,
    profile_id: String,
}

impl Default for OtherLayer {
    fn default() -> Self {
        Self {
            enabled: true,
            profile_id: String::new(),
        }
    }
}

impl Layer {
    fn enabled(&self) -> bool {
        match self {
            Self::Ssh(ssh) => ssh.enabled,
            Self::Proxy(other) | Self::HttpTunnel(other) => other.enabled,
        }
    }

    fn profile_id(&self) -> &str {
        match self {
            Self::Ssh(ssh) => ssh.profile_id.trim(),
            Self::Proxy(other) | Self::HttpTunnel(other) => other.profile_id.trim(),
        }
    }

    fn lost_as(&self) -> &'static str {
        match self {
            Self::Ssh(_) => SSH_TUNNEL,
            Self::Proxy(_) => PROXY,
            Self::HttpTunnel(_) => HTTP_TUNNEL,
        }
    }
}

impl Config {
    // The SSH hops DBX connects through, first to last, and the review key of each part of the route
    // TablePro has no field for. A layer that names a shared tunnel profile takes that profile's
    // settings, as DBX does at connect time.
    pub(super) fn route(&self, profiles: &HashMap<String, Layer>) -> (Vec<SshLayer>, BTreeSet<&'static str>) {
        let mut hops = Vec::new();
        let mut lost = BTreeSet::new();
        for layer in self.layers().into_iter().filter(Layer::enabled) {
            let resolved = match layer.profile_id() {
                "" => Some(layer.clone()),
                id => profiles.get(id).cloned(),
            };
            match resolved {
                Some(Layer::Ssh(ssh)) if !ssh.host.trim().is_empty() => {
                    if !ssh.proxy_command.trim().is_empty() {
                        lost.insert(PROXY_COMMAND);
                    }
                    hops.push(ssh);
                }
                Some(other) => {
                    lost.insert(other.lost_as());
                }
                None => {
                    lost.insert(layer.lost_as());
                }
            }
        }
        (hops, lost)
    }

    fn layers(&self) -> Vec<Layer> {
        if !self.transport_layers.is_empty() {
            return self.transport_layers.clone();
        }
        let mut layers = Vec::new();
        if self.ssh_enabled == Some(true) {
            let hops = self.ssh_tunnels.as_deref().unwrap_or_default();
            if !hops.is_empty() {
                layers.extend(hops.iter().cloned().map(Layer::Ssh));
            } else if let Some(host) = named(self.ssh_host.as_deref()) {
                layers.push(Layer::Ssh(SshLayer {
                    host: host.to_owned(),
                    port: self.ssh_port.filter(|port| *port > 0).unwrap_or(22),
                    user: self.ssh_user.clone().unwrap_or_default(),
                    key_path: self.ssh_key_path.clone().unwrap_or_default(),
                    ..SshLayer::default()
                }));
            }
        }
        if self.proxy_enabled == Some(true) && named(self.proxy_host.as_deref()).is_some() {
            layers.push(Layer::Proxy(OtherLayer::default()));
        }
        layers
    }
}

fn named(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(json: &str) -> Config {
        serde_json::from_str(json).expect("a config")
    }

    fn hosts(hops: &[SshLayer]) -> Vec<&str> {
        hops.iter().map(|hop| hop.host.as_str()).collect()
    }

    #[test]
    fn hops_keep_their_order_and_a_disabled_one_is_left_out() {
        let config = config(
            r#"{"transport_layers":[{"type":"ssh","host":"edge"},{"type":"ssh","host":"off","enabled":false},
                {"type":"ssh","host":"inner","port":2222}]}"#,
        );

        let (hops, lost) = config.route(&HashMap::new());

        assert_eq!(hosts(&hops), ["edge", "inner"]);
        assert_eq!(hops[1].port, 2222);
        assert!(lost.is_empty());
    }

    #[test]
    fn a_layer_on_a_tunnel_profile_takes_the_profiles_settings_or_is_lost() {
        let profile: Layer =
            serde_json::from_str(r#"{"type":"ssh","host":"shared","user":"ops","enabled":false}"#).expect("a profile");
        let profiles = HashMap::from([("p1".to_owned(), profile)]);
        let config = config(
            r#"{"transport_layers":[{"type":"ssh","profile_id":"p1"},
                {"type":"ssh","profile_id":"gone","host":"stale"}]}"#,
        );

        let (hops, lost) = config.route(&profiles);

        assert_eq!(hosts(&hops), ["shared"]);
        assert_eq!(hops[0].user, "ops");
        assert_eq!(lost, BTreeSet::from([SSH_TUNNEL]));
    }

    #[test]
    fn a_proxy_a_script_tunnel_and_a_proxy_command_are_named_as_lost() {
        let config = config(
            r#"{"transport_layers":[{"type":"proxy","host":"socks"},{"type":"http_tunnel","url":"https://x/t.php"},
                {"type":"ssh","host":"bastion","proxy_command":"nc %h %p"}]}"#,
        );

        let (hops, lost) = config.route(&HashMap::new());

        assert_eq!(hosts(&hops), ["bastion"]);
        assert_eq!(lost, BTreeSet::from([HTTP_TUNNEL, PROXY, PROXY_COMMAND]));
    }

    #[test]
    fn a_connection_saved_before_layers_reads_as_dbx_reads_it() {
        let single = config(
            r#"{"ssh_enabled":true,"ssh_host":" bastion ","ssh_port":0,"ssh_user":"ops",
                "proxy_enabled":true,"proxy_host":"socks"}"#,
        );
        let (hops, lost) = single.route(&HashMap::new());
        assert_eq!(hosts(&hops), ["bastion"]);
        assert_eq!((hops[0].port, hops[0].user.as_str()), (22, "ops"));
        assert_eq!(lost, BTreeSet::from([PROXY]));

        let chained =
            config(r#"{"ssh_enabled":true,"ssh_host":"ignored","ssh_tunnels":[{"host":"edge"},{"host":"inner"}]}"#);
        assert_eq!(hosts(&chained.route(&HashMap::new()).0), ["edge", "inner"]);

        let off = config(r#"{"ssh_enabled":false,"ssh_host":"bastion"}"#);
        assert!(off.route(&HashMap::new()).0.is_empty());
    }
}
