#[cfg(feature = "dns-resolver")]
use hickory_resolver::config::ResolverConfig as HickoryResolverConfig;

/// Configuration for the upstream nameservers to use for resolution.
///
/// This is a thin wrapper around a `hickory_resolver::config::ResolverConfig` provided to ensure
/// API stability.
#[derive(Clone, Debug)]
#[cfg_attr(not(feature = "dns-resolver"), derive(PartialEq))]
pub struct ResolverConfig {
    #[cfg(feature = "dns-resolver")]
    pub(crate) inner: HickoryResolverConfig,
}

#[cfg(feature = "dns-resolver")]
impl PartialEq for ResolverConfig {
    fn eq(&self, other: &Self) -> bool {
        let (left, right) = (&self.inner, &other.inner);

        if !(left.domain() == right.domain()
            && left.search() == right.search()
            && left.name_servers().len() == right.name_servers().len())
        {
            return false;
        }

        for (a, b) in std::iter::zip(left.name_servers(), right.name_servers()) {
            if !(a.ip == b.ip
                && a.trust_negative_responses == b.trust_negative_responses
                && a.connections.len() == b.connections.len()
                && std::iter::zip(&a.connections, &b.connections).all(|(ca, cb)| {
                    ca.port == cb.port && ca.protocol == cb.protocol && ca.bind_addr == cb.bind_addr
                }))
            {
                return false;
            }
        }

        true
    }
}

#[cfg(feature = "dns-resolver")]
impl ResolverConfig {
    /// Creates a default configuration, using 1.1.1.1, 1.0.0.1 and 2606:4700:4700::1111,
    /// 2606:4700:4700::1001 (thank you, Cloudflare).
    ///
    /// Please see: <https://www.cloudflare.com/dns/>
    pub fn cloudflare() -> Self {
        ResolverConfig {
            inner: HickoryResolverConfig::udp_and_tcp(&hickory_resolver::config::CLOUDFLARE),
        }
    }

    /// Creates a default configuration, using 8.8.8.8, 8.8.4.4 and 2001:4860:4860::8888,
    /// 2001:4860:4860::8844 (thank you, Google).
    ///
    /// Please see Google’s privacy statement for important information about what they track, many
    /// ISP’s track similar information in DNS.
    pub fn google() -> Self {
        ResolverConfig {
            inner: HickoryResolverConfig::udp_and_tcp(&hickory_resolver::config::GOOGLE),
        }
    }

    /// Creates a configuration, using 9.9.9.9, 149.112.112.112 and 2620:fe::fe, 2620:fe::fe:9, the
    /// “secure” variants of the quad9 settings (thank you, Quad9).
    ///
    /// Please see: <https://www.quad9.net/faq/>
    pub fn quad9() -> Self {
        ResolverConfig {
            inner: HickoryResolverConfig::udp_and_tcp(&hickory_resolver::config::QUAD9),
        }
    }
}
