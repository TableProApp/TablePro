use crate::{
    action::{action_impl, ParseConnectionString},
    error::{Error, Result},
    srv::OriginalSrvInfo,
};

use super::{ClientOptions, ConnectionString, ResolvedHostInfo, Tls};

#[action_impl]
impl Action for ParseConnectionString {
    type Future = ParseFuture;

    async fn execute(self) -> Result<ClientOptions> {
        let mut conn_str = self.conn_str?;
        #[allow(deprecated)]
        if conn_str.socket_timeout.is_some() {
            return Err(Error::invalid_argument(
                "the Rust driver does not support socketTimeoutMS",
            ));
        }
        let auth_source_present = conn_str
            .credential
            .as_ref()
            .and_then(|cred| cred.source.as_ref())
            .is_some();
        let host_info = std::mem::take(&mut conn_str.host_info);
        let mut options = ClientOptions::from_connection_string(conn_str);
        #[cfg(feature = "dns-resolver")]
        {
            options.resolver_config.clone_from(&self.resolver_config);
        }

        let resolved = host_info
            .resolve(self.resolver_config, options.srv_service_name.clone())
            .await?;
        options.hosts = match resolved {
            ResolvedHostInfo::HostIdentifiers(hosts) => hosts,
            ResolvedHostInfo::DnsRecord {
                hostname,
                mut config,
            } => {
                // Save the original SRV info to allow mongos polling.
                options.original_srv_info = OriginalSrvInfo {
                    hostname,
                    min_ttl: config.min_ttl,
                }
                .into();

                // Enable TLS unless the user explicitly disabled it.
                if options.tls.is_none() {
                    options.tls = Some(Tls::Enabled(Default::default()));
                }

                // Set the authSource TXT option found during SRV lookup unless the user already set
                // it. Note that this _does_ override the default database specified
                // in the URI, since it is supposed to be overriden by authSource.
                if !auth_source_present {
                    if let Some(auth_source) = config.auth_source.take() {
                        if let Some(ref mut credential) = options.credential {
                            credential.source = Some(auth_source);
                        }
                    }
                }

                // Set the replica set name TXT option found during SRV lookup unless the user
                // already set it.
                if options.repl_set_name.is_none() {
                    if let Some(replica_set) = config.replica_set.take() {
                        options.repl_set_name = Some(replica_set);
                    }
                }

                if options.load_balanced.is_none() {
                    options.load_balanced = config.load_balanced;
                }

                if let Some(max) = options.srv_max_hosts {
                    if max > 0 {
                        if options.repl_set_name.is_some() {
                            return Err(Error::invalid_argument(
                                "srvMaxHosts and replicaSet cannot both be present",
                            ));
                        }
                        if options.load_balanced == Some(true) {
                            return Err(Error::invalid_argument(
                                "srvMaxHosts and loadBalanced=true cannot both be present",
                            ));
                        }
                        config.hosts = crate::sdam::choose_n(&config.hosts, max as usize)
                            .cloned()
                            .collect();
                    }
                }

                // Set the ClientOptions hosts to those found during the SRV lookup.
                config.hosts
            }
        };

        options.validate()?;
        Ok(options)
    }
}

impl ClientOptions {
    fn from_connection_string(conn_str: ConnectionString) -> Self {
        let mut credential = conn_str.credential;
        // Populate default auth source, if needed.
        let db = &conn_str.default_database;
        if let Some(credential) = credential.as_mut() {
            if credential.source.is_none() {
                credential.source = match &credential.mechanism {
                    Some(mechanism) => Some(mechanism.default_source(db.as_deref()).into()),
                    None => {
                        // If credentials exist (i.e. username is specified) but no mechanism, the
                        // default source is chosen from the following list in
                        // order (skipping null ones): authSource option, connection string db,
                        // SCRAM default (i.e. "admin").
                        db.clone().or_else(|| Some("admin".into()))
                    }
                };
            }
        }

        Self {
            hosts: vec![],
            app_name: conn_str.app_name,
            tls: conn_str.tls,
            heartbeat_freq: conn_str.heartbeat_frequency,
            local_threshold: conn_str.local_threshold,
            read_concern: conn_str.read_concern,
            selection_criteria: conn_str.read_preference.map(Into::into),
            repl_set_name: conn_str.replica_set,
            write_concern: conn_str.write_concern,
            max_pool_size: conn_str.max_pool_size,
            min_pool_size: conn_str.min_pool_size,
            max_idle_time: conn_str.max_idle_time,
            max_connecting: conn_str.max_connecting,
            server_selection_timeout: conn_str.server_selection_timeout,
            #[cfg(any(
                feature = "zstd-compression",
                feature = "zlib-compression",
                feature = "snappy-compression"
            ))]
            compressors: conn_str.compressors,
            connect_timeout: conn_str.connect_timeout,
            retry_reads: conn_str.retry_reads,
            retry_writes: conn_str.retry_writes,
            server_monitoring_mode: conn_str.server_monitoring_mode,
            direct_connection: conn_str.direct_connection,
            default_database: conn_str.default_database,
            driver_info: None,
            credential,
            cmap_event_handler: None,
            command_event_handler: None,
            original_srv_info: None,
            #[cfg(test)]
            original_uri: Some(conn_str.original_uri),
            #[cfg(feature = "dns-resolver")]
            resolver_config: None,
            server_api: None,
            load_balanced: conn_str.load_balanced,
            sdam_event_handler: None,
            #[cfg(test)]
            test_options: None,
            #[cfg(feature = "tracing-unstable")]
            tracing_max_document_length_bytes: None,
            srv_max_hosts: conn_str.srv_max_hosts,
            srv_service_name: conn_str.srv_service_name,
            #[cfg(feature = "opentelemetry")]
            tracing: None,
            #[cfg(feature = "socks5-proxy")]
            socks5_proxy: conn_str.socks5_proxy,
            adaptive_retries: conn_str.adaptive_retries,
            max_adaptive_retries: conn_str.max_adaptive_retries,
            enable_overload_retargeting: conn_str.enable_overload_retargeting,
        }
    }
}
