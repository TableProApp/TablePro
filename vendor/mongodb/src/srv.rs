use std::time::Duration;

#[cfg(feature = "dns-resolver")]
use crate::error::{ErrorKind, Redact};
use crate::{client::options::ResolverConfig, error::Result, options::ServerAddress};
#[cfg(feature = "dns-resolver")]
use hickory_proto::rr::RData;

#[derive(Debug)]
pub(crate) struct ResolvedConfig {
    pub(crate) hosts: Vec<ServerAddress>,
    pub(crate) min_ttl: Duration,
    pub(crate) auth_source: Option<String>,
    pub(crate) replica_set: Option<String>,
    pub(crate) load_balanced: Option<bool>,
}

#[derive(Debug, Clone)]
pub(crate) struct LookupHosts {
    pub(crate) hosts: Vec<ServerAddress>,
    pub(crate) min_ttl: Duration,
}

impl LookupHosts {
    #[cfg(feature = "dns-resolver")]
    pub(crate) fn validate(mut self, original_hostname: &str, dm: DomainMismatch) -> Result<Self> {
        let original_hostname_parts: Vec<_> = original_hostname.split('.').collect();
        let original_domain_name = if original_hostname_parts.len() >= 3 {
            &original_hostname_parts[1..]
        } else {
            &original_hostname_parts[..]
        };

        let mut ok_hosts = vec![];
        for addr in self.hosts.drain(..) {
            let host = addr.host();
            let hostname_parts: Vec<_> = host.split('.').collect();
            if hostname_parts[1..].ends_with(original_domain_name) {
                ok_hosts.push(addr);
            } else {
                let message = format!(
                    "SRV lookup for {} returned result {}, which does not match domain name {}",
                    original_hostname,
                    host,
                    original_domain_name.join(".")
                );
                match dm {
                    DomainMismatch::Error => return Err(ErrorKind::DnsResolve { message }.into()),
                    DomainMismatch::Skip => {
                        #[cfg(feature = "tracing-unstable")]
                        {
                            use crate::trace::SERVER_SELECTION_TRACING_EVENT_TARGET;
                            if crate::trace::trace_or_log_enabled!(
                                target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                                crate::trace::TracingOrLogLevel::Warn
                            ) {
                                tracing::warn!(
                                    target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                                    message,
                                );
                            }
                        }
                        continue;
                    }
                }
            }
        }
        self.hosts = ok_hosts;

        if self.hosts.is_empty() {
            return Err(ErrorKind::DnsResolve {
                message: format!(
                    "SRV lookup for {} returned no records",
                    Redact(original_hostname)
                ),
            }
            .into());
        }

        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct OriginalSrvInfo {
    pub(crate) hostname: String,
    pub(crate) min_ttl: Duration,
}

pub(crate) enum DomainMismatch {
    #[allow(dead_code)]
    Error,
    Skip,
}

#[cfg(feature = "dns-resolver")]
pub(crate) struct SrvResolver {
    resolver: crate::runtime::AsyncResolver,
    srv_service_name: Option<String>,
}

#[cfg(feature = "dns-resolver")]
impl SrvResolver {
    pub(crate) async fn new(
        config: Option<ResolverConfig>,
        srv_service_name: Option<String>,
    ) -> Result<Self> {
        let resolver = crate::runtime::AsyncResolver::new(config.map(|c| c.inner)).await?;

        Ok(Self {
            resolver,
            srv_service_name,
        })
    }

    pub(crate) async fn resolve_client_options(
        &mut self,
        hostname: &str,
    ) -> Result<ResolvedConfig> {
        let lookup_result = self.get_srv_hosts(hostname, DomainMismatch::Error).await?;
        let mut config = ResolvedConfig {
            hosts: lookup_result.hosts,
            min_ttl: lookup_result.min_ttl,
            auth_source: None,
            replica_set: None,
            load_balanced: None,
        };

        self.get_txt_options(hostname, &mut config).await?;

        Ok(config)
    }

    async fn get_srv_hosts_unvalidated(&self, lookup_hostname: &str) -> Result<LookupHosts> {
        let srv_lookup = self.resolver.srv_lookup(lookup_hostname).await?;
        let mut hosts = vec![];
        let mut min_ttl = u32::MAX;
        for record in srv_lookup.answers() {
            let RData::SRV(srv) = &record.data else {
                continue;
            };
            let mut host = srv.target.to_utf8();
            // Remove the trailing '.'
            if host.ends_with('.') {
                host.pop();
            }
            let port = Some(srv.port);
            hosts.push(ServerAddress::Tcp { host, port });
            min_ttl = std::cmp::min(min_ttl, record.ttl);
        }
        Ok(LookupHosts {
            hosts,
            min_ttl: Duration::from_secs(min_ttl.into()),
        })
    }

    pub(crate) async fn get_srv_hosts(
        &self,
        original_hostname: &str,
        dm: DomainMismatch,
    ) -> Result<LookupHosts> {
        let lookup_hostname = format!(
            "_{}._tcp.{}",
            self.srv_service_name.as_deref().unwrap_or("mongodb"),
            original_hostname
        );
        self.get_srv_hosts_unvalidated(&lookup_hostname)
            .await?
            .validate(original_hostname, dm)
    }

    async fn get_txt_options(
        &self,
        original_hostname: &str,
        config: &mut ResolvedConfig,
    ) -> Result<()> {
        let txt_records_response = match self.resolver.txt_lookup(original_hostname).await? {
            Some(response) => response,
            None => return Ok(()),
        };
        let mut txt_records =
            txt_records_response
                .answers()
                .iter()
                .filter_map(|record| match &record.data {
                    RData::TXT(txt) => Some(txt),
                    _ => None,
                });

        let txt_record = match txt_records.next() {
            Some(record) => record,
            None => return Ok(()),
        };

        if txt_records.next().is_some() {
            return Err(ErrorKind::DnsResolve {
                message: format!(
                    "TXT lookup for {} returned more than one record, but more than one are not \
                     allowed with 'mongodb+srv'",
                    Redact(original_hostname),
                ),
            }
            .into());
        }

        let txt_data: Vec<_> = txt_record
            .txt_data
            .iter()
            .map(|bytes| String::from_utf8_lossy(bytes.as_ref()).into_owned())
            .collect();

        let txt_string = txt_data.join("");

        for option_pair in txt_string.split('&') {
            let parts: Vec<_> = option_pair.split('=').collect();

            if parts.len() != 2 {
                return Err(ErrorKind::DnsResolve {
                    message: format!(
                        "TXT record string '{option_pair}' is not a value `key=value` option pair"
                    ),
                }
                .into());
            }

            match &parts[0].to_lowercase()[..] {
                "authsource" => {
                    config.auth_source = Some(parts[1].to_string());
                }
                "replicaset" => {
                    config.replica_set = Some(parts[1].into());
                }
                "loadbalanced" => {
                    let val = match parts[1] {
                        "true" => true,
                        "false" => false,
                        _ => {
                            return Err(ErrorKind::DnsResolve {
                                message: format!(
                                    "TXT record option 'loadbalanced={}' was returned, only \
                                     'true' and 'false' are allowed values.",
                                    parts[1]
                                ),
                            }
                            .into())
                        }
                    };
                    config.load_balanced = Some(val);
                }
                other => {
                    return Err(ErrorKind::DnsResolve {
                        message: format!(
                            "TXT record option '{other}' was returned, but only 'authSource', \
                             'replicaSet', and 'loadBalanced' are allowed"
                        ),
                    }
                    .into())
                }
            };
        }

        Ok(())
    }
}

/// Stub implementation when dns resolution isn't enabled.
#[cfg(not(feature = "dns-resolver"))]
pub(crate) struct SrvResolver {}

#[cfg(not(feature = "dns-resolver"))]
impl SrvResolver {
    pub(crate) async fn new(
        _config: Option<ResolverConfig>,
        _srv_service_name: Option<String>,
    ) -> Result<Self> {
        Ok(Self {})
    }

    pub(crate) async fn resolve_client_options(
        &mut self,
        _hostname: &str,
    ) -> Result<ResolvedConfig> {
        Err(crate::error::Error::invalid_argument(
            "mongodb+srv connection strings cannot be used when the 'dns-resolver' feature is \
             disabled",
        ))
    }

    pub(crate) async fn get_srv_hosts(
        &self,
        _original_hostname: &str,
        _dm: DomainMismatch,
    ) -> Result<LookupHosts> {
        return Err(crate::error::Error::invalid_argument(
            "mongodb+srv connection strings cannot be used when the 'dns-resolver' feature is \
             disabled",
        ));
    }
}
