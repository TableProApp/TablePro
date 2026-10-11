use crate::error::{Error, Result};
use hickory_resolver::{config::ResolverConfig, lookup::Lookup, proto::rr::Name};

#[cfg(feature = "gssapi-auth")]
use hickory_resolver::{lookup_ip::LookupIp, proto::rr::RecordType};
#[cfg(feature = "gssapi-auth")]
use std::net::IpAddr;

/// An async runtime agnostic DNS resolver.
pub(crate) struct AsyncResolver {
    resolver: hickory_resolver::TokioResolver,
}

impl AsyncResolver {
    pub(crate) async fn new(config: Option<ResolverConfig>) -> Result<Self> {
        let resolver = match config {
            Some(config) => {
                hickory_resolver::TokioResolver::builder_with_config(config, Default::default())
            }
            None => hickory_resolver::TokioResolver::builder_tokio()
                .map_err(Error::from_resolve_error)?,
        }
        .build()
        .map_err(Error::from_resolve_error)?;

        Ok(Self { resolver })
    }
}

impl AsyncResolver {
    #[cfg(feature = "gssapi-auth")]
    pub async fn cname_lookup(&self, query: &str) -> Result<Lookup> {
        let name = Name::from_str_relaxed(query).map_err(Error::from_resolve_proto_error)?;
        let lookup = self
            .resolver
            .lookup(name, RecordType::CNAME)
            .await
            .map_err(Error::from_resolve_error)?;
        Ok(lookup)
    }

    #[cfg(feature = "gssapi-auth")]
    pub async fn ip_lookup(&self, query: &str) -> Result<LookupIp> {
        let name = Name::from_str_relaxed(query).map_err(Error::from_resolve_proto_error)?;
        let lookup = self
            .resolver
            .lookup_ip(name)
            .await
            .map_err(Error::from_resolve_error)?;
        Ok(lookup)
    }

    #[cfg(feature = "gssapi-auth")]
    pub async fn reverse_lookup(&self, ip_addr: IpAddr) -> Result<Lookup> {
        let lookup = self
            .resolver
            .reverse_lookup(ip_addr)
            .await
            .map_err(Error::from_resolve_error)?;
        Ok(lookup)
    }

    pub async fn srv_lookup(&self, query: &str) -> Result<Lookup> {
        let name = Name::from_str_relaxed(query).map_err(Error::from_resolve_proto_error)?;
        let lookup = self
            .resolver
            .srv_lookup(name)
            .await
            .map_err(Error::from_resolve_error)?;
        Ok(lookup)
    }

    pub async fn txt_lookup(&self, query: &str) -> Result<Option<Lookup>> {
        let name = Name::from_str_relaxed(query).map_err(Error::from_resolve_proto_error)?;
        let lookup_result = self.resolver.txt_lookup(name).await;
        match lookup_result {
            Ok(lookup) => Ok(Some(lookup)),
            Err(e) if e.is_no_records_found() => Ok(None),
            Err(e) => Err(Error::from_resolve_error(e)),
        }
    }
}
