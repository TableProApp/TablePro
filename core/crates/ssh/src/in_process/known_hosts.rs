use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use aws_lc_rs::hmac;
use russh::keys::ssh_key::certificate::CertType;
use russh::keys::ssh_key::known_hosts::{Entry, HostPatterns, Marker};
use russh::keys::ssh_key::public::KeyData;
use russh::keys::ssh_key::{Algorithm, Certificate, HashAlg, PublicKey};

// Lower case, and the port in brackets unless it is 22, as OpenSSH files a host.
pub(crate) fn lookup_name(host: &str, port: u16) -> String {
    let host = host.to_ascii_lowercase();
    if port == 22 { host } else { format!("[{host}]:{port}") }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Verdict {
    Trusted,
    Unknown,
    Changed { path: PathBuf, line: usize },
    Revoked { path: PathBuf, line: usize },
}

#[derive(Debug, Clone)]
pub(crate) struct KnownKey {
    pub path: PathBuf,
    pub line: usize,
    marker: Option<Marker>,
    key: PublicKey,
}

// A missing file names nothing, and a line ssh could not read either, bytes that are not UTF-8 included, is skipped.
pub(crate) fn read_known(path: &Path, name: &str) -> io::Result<Vec<KnownKey>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    Ok(bytes
        .split(|&byte| byte == b'\n')
        .enumerate()
        .filter_map(|(index, raw)| {
            let entry = parse_line(std::str::from_utf8(raw).ok()?)?;
            names_host(entry.host_patterns(), name).then(|| KnownKey {
                path: path.to_owned(),
                line: index + 1,
                marker: entry.marker().copied(),
                key: entry.public_key().clone(),
            })
        })
        .collect())
}

// What OpenSSH asks the server for first: the key types the host is known by, and certificates
// when an authority vouches for it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct KnownTypes {
    pub plain: Vec<Algorithm>,
    pub authority: bool,
}

pub(crate) fn known_types(known: &[KnownKey]) -> KnownTypes {
    let mut types = KnownTypes::default();
    for entry in known {
        match entry.marker {
            None => {
                let algorithm = entry.key.algorithm();
                if !types.plain.contains(&algorithm) {
                    types.plain.push(algorithm);
                }
            }
            Some(Marker::CertAuthority) => types.authority = true,
            Some(Marker::Revoked) => {}
        }
    }
    types
}

// OpenSSH's decision over every line naming the host; `principal` is the name a host certificate must list.
pub(crate) fn verdict(
    known: &[KnownKey],
    key: &PublicKey,
    certificate: Option<&Certificate>,
    principal: &str,
    now: u64,
) -> Verdict {
    let authority = certificate.map(Certificate::signature_key);
    let revoked = known.iter().find(|entry| {
        entry.marker == Some(Marker::Revoked)
            && (entry.key.key_data() == key.key_data() || authority.is_some_and(|ca| entry.key.key_data() == ca))
    });
    if let Some(entry) = revoked {
        return Verdict::Revoked {
            path: entry.path.clone(),
            line: entry.line,
        };
    }
    if let Some(certificate) = certificate
        && known.iter().any(|entry| {
            entry.marker == Some(Marker::CertAuthority) && certified(certificate, entry.key.key_data(), principal, now)
        })
    {
        return Verdict::Trusted;
    }
    // A certificate no authority vouches for is checked as the plain key it carries, as OpenSSH does.
    let mut plain = known.iter().filter(|entry| entry.marker.is_none());
    if plain.clone().any(|entry| entry.key.key_data() == key.key_data()) {
        return Verdict::Trusted;
    }
    match plain.find(|entry| entry.key.algorithm() == key.algorithm()) {
        Some(entry) => Verdict::Changed {
            path: entry.path.clone(),
            line: entry.line,
        },
        None => Verdict::Unknown,
    }
}

fn certified(certificate: &Certificate, authority: &KeyData, principal: &str, now: u64) -> bool {
    let fingerprint = authority.fingerprint(HashAlg::Sha256);
    certificate.cert_type() == CertType::Host
        && certificate.signature_key() == authority
        && certificate.critical_options().is_empty()
        && (certificate.valid_principals().is_empty()
            || certificate
                .valid_principals()
                .iter()
                .any(|listed| listed.eq_ignore_ascii_case(principal)))
        && certificate.validate_at(now, [&fingerprint]).is_ok()
}

pub(crate) fn append(path: &Path, name: &str, key: &PublicKey) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no home directory"));
    }
    if let Some(dir) = path.parent() {
        create_ssh_dir(dir)?;
    }
    let text = PublicKey::new(key.key_data().clone(), "")
        .to_openssh()
        .map_err(io::Error::other)?;
    let needs_newline = fs::read(path).is_ok_and(|bytes| !bytes.is_empty() && !bytes.ends_with(b"\n"));
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    let mut line = String::new();
    if needs_newline {
        line.push('\n');
    }
    line.push_str(&format!("{name} {text}\n"));
    file.write_all(line.as_bytes())
}

// As `ssh-keygen -R`: plain key lines for the host go, markers and the rest stay as they were.
pub(crate) fn forget_host(path: &Path, name: &str) -> io::Result<()> {
    let bytes = fs::read(path)?;
    let forgotten = |raw: &[u8]| {
        std::str::from_utf8(raw)
            .ok()
            .and_then(parse_line)
            .is_some_and(|entry| entry.marker().is_none() && names_host(entry.host_patterns(), name))
    };
    let kept: Vec<u8> = bytes
        .split_inclusive(|&byte| byte == b'\n')
        .filter(|raw| !forgotten(raw))
        .flatten()
        .copied()
        .collect();
    if kept.len() == bytes.len() {
        return Ok(());
    }
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut replacement = tempfile::NamedTempFile::new_in(dir)?;
    replacement.write_all(&kept)?;
    replacement.as_file().sync_all()?;
    replacement.persist(path).map_err(|error| error.error)?;
    Ok(())
}

// ssh-key splits fields on one space, where OpenSSH takes any run of blanks and a trailing comment.
fn parse_line(raw: &str) -> Option<Entry> {
    let line = raw.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let fields: Vec<&str> = line.split_whitespace().collect();
    let wanted = if line.starts_with('@') { 4 } else { 3 };
    fields.get(..wanted)?.join(" ").parse().ok()
}

fn names_host(patterns: &HostPatterns, name: &str) -> bool {
    match patterns {
        HostPatterns::HashedName { salt, hash } => {
            let key = hmac::Key::new(hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, salt);
            hmac::verify(&key, name.as_bytes(), hash).is_ok()
        }
        HostPatterns::Patterns(patterns) => {
            let mut named = false;
            for pattern in patterns {
                match pattern.strip_prefix('!') {
                    Some(negated) if wildcard(negated, name) => return false,
                    Some(_) => {}
                    None => named |= wildcard(pattern, name),
                }
            }
            named
        }
    }
}

// `*` and `?` as OpenSSH's match_pattern reads them, ignoring case.
fn wildcard(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.to_lowercase().chars().collect();
    let text: Vec<char> = text.to_lowercase().chars().collect();
    let (mut p, mut t) = (0, 0);
    let mut retry: Option<(usize, usize)> = None;
    while t < text.len() {
        match pattern.get(p) {
            Some('*') => {
                retry = Some((p, t));
                p += 1;
            }
            Some(&c) if c == '?' || c == text[t] => {
                p += 1;
                t += 1;
            }
            _ => match retry {
                Some((star, matched)) => {
                    p = star + 1;
                    t = matched + 1;
                    retry = Some((star, matched + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|&c| c == '*')
}

#[cfg(unix)]
fn create_ssh_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)
}

#[cfg(not(unix))]
fn create_ssh_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

#[cfg(test)]
mod tests {
    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::ssh_key::{PrivateKey, certificate};

    use super::*;

    const ECDSA: &str = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHwf2HMM5TRXvo2SQJjsNkiDD5KqiiNjrGVv3UUh+mMT5RHxiRtOnlqvjhQtBq0VpmpCV/PwUdhOig4vkbqAcEc=";

    fn ed25519_private(seed: u8) -> PrivateKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
    }

    fn ed25519(seed: u8) -> PublicKey {
        ed25519_private(seed).public_key().clone()
    }

    fn line(key: &PublicKey) -> String {
        key.to_openssh().unwrap()
    }

    fn ecdsa() -> PublicKey {
        PublicKey::from_openssh(ECDSA).unwrap()
    }

    fn known_file(contents: &str) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        fs::write(&path, contents).unwrap();
        (dir, path)
    }

    fn decide(contents: &str, name: &str, presented: &PublicKey) -> Verdict {
        let (_dir, path) = known_file(contents);
        let known = read_known(&path, name).unwrap();
        verdict(&known, presented, None, "db.internal", 0)
    }

    #[test]
    fn the_lookup_name_brackets_a_port_other_than_22() {
        assert_eq!(lookup_name("Bastion.Example.com", 22), "bastion.example.com");
        assert_eq!(lookup_name("db.internal", 2222), "[db.internal]:2222");
        assert_eq!(lookup_name("fd00::1", 2200), "[fd00::1]:2200");
    }

    #[test]
    fn patterns_take_wildcards_and_a_negation_wins() {
        let patterns = |list: &[&str]| HostPatterns::Patterns(list.iter().map(|p| (*p).to_owned()).collect());

        assert!(names_host(&patterns(&["*.example.com"]), "db.example.com"));
        assert!(names_host(&patterns(&["db?.example.com"]), "db1.example.com"));
        assert!(names_host(&patterns(&["[db.internal]:2222"]), "[db.internal]:2222"));
        assert!(!names_host(&patterns(&["db.internal"]), "[db.internal]:2222"));
        assert!(!names_host(
            &patterns(&["*.example.com", "!db.example.com"]),
            "db.example.com"
        ));
        assert!(names_host(
            &patterns(&["*.example.com", "!db.example.com"]),
            "web.example.com"
        ));
        assert!(names_host(&patterns(&["DB.Example.COM"]), "db.example.com"));
        assert!(!names_host(&patterns(&["!db.example.com"]), "web.example.com"));
    }

    #[test]
    fn a_hashed_name_matches_only_its_host() {
        let salt = b"0123456789abcdefghij".to_vec();
        let signature = hmac::sign(
            &hmac::Key::new(hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, &salt),
            b"[db.internal]:2222",
        );
        let mut hash = [0_u8; 20];
        hash.copy_from_slice(signature.as_ref());
        let hashed = HostPatterns::HashedName { salt, hash };

        assert!(names_host(&hashed, "[db.internal]:2222"));
        assert!(!names_host(&hashed, "db.internal"));
    }

    #[test]
    fn a_known_key_is_trusted_and_blanks_and_comments_are_read_as_ssh_reads_them() {
        let contents = format!(
            "# comment\n\n@cert-authority *.example.com {ECDSA}\ndb.internal\t{}   laptop\n",
            line(&ed25519(1))
        );

        assert_eq!(decide(&contents, "db.internal", &ed25519(1)), Verdict::Trusted);
    }

    #[test]
    fn another_key_of_the_same_type_is_a_change_on_its_line() {
        let contents = format!(
            "other {}\ndb.internal,10.0.0.5 {}\n",
            line(&ed25519(1)),
            line(&ed25519(2))
        );

        assert!(matches!(
            decide(&contents, "db.internal", &ed25519(1)),
            Verdict::Changed { line: 2, .. }
        ));
    }

    #[test]
    fn a_key_of_another_type_or_no_line_at_all_is_unknown() {
        let contents = format!("db.internal {ECDSA}\n");

        assert_eq!(decide(&contents, "db.internal", &ed25519(1)), Verdict::Unknown);
        assert_eq!(decide("", "db.internal", &ed25519(1)), Verdict::Unknown);
        assert_eq!(decide(&contents, "[db.internal]:2222", &ecdsa()), Verdict::Unknown);
    }

    #[test]
    fn a_revoked_key_is_refused_even_when_listed_as_trusted() {
        let key = line(&ed25519(1));
        let contents = format!("db.internal {key}\n@revoked * {key}\n");

        assert!(matches!(
            decide(&contents, "db.internal", &ed25519(1)),
            Verdict::Revoked { line: 2, .. }
        ));
    }

    #[test]
    fn a_host_certificate_from_a_listed_authority_is_trusted_for_its_principals() {
        let authority = ed25519_private(9);
        let host_key = ecdsa();
        let sign = |principal: &str, cert_type: CertType| {
            let mut builder = certificate::Builder::new(vec![7; 16], host_key.key_data().clone(), 100, 200).unwrap();
            builder.cert_type(cert_type).unwrap();
            builder.valid_principal(principal).unwrap();
            builder.sign(&authority).unwrap()
        };
        let (_dir, path) = known_file(&format!(
            "@cert-authority *.internal {}\n",
            line(authority.public_key())
        ));
        let known = read_known(&path, "db.internal").unwrap();

        let trusted = sign("db.internal", CertType::Host);
        let wrong_host = sign("web.internal", CertType::Host);
        let user_cert = sign("db.internal", CertType::User);

        assert_eq!(
            verdict(&known, &host_key, Some(&trusted), "db.internal", 150),
            Verdict::Trusted
        );
        assert_eq!(
            verdict(&known, &host_key, Some(&trusted), "db.internal", 250),
            Verdict::Unknown
        );
        assert_eq!(
            verdict(&known, &host_key, Some(&wrong_host), "db.internal", 150),
            Verdict::Unknown
        );
        assert_eq!(
            verdict(&known, &host_key, Some(&user_cert), "db.internal", 150),
            Verdict::Unknown
        );
    }

    #[test]
    fn a_trusted_key_is_appended_on_a_line_of_its_own_and_read_back() {
        let (_dir, path) = known_file(&format!("other {ECDSA}"));

        append(&path, "[db.internal]:2222", &ed25519(1)).unwrap();

        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(
            text,
            format!("other {ECDSA}\n[db.internal]:2222 {}\n", line(&ed25519(1)))
        );
        let known = read_known(&path, "[db.internal]:2222").unwrap();
        assert_eq!(verdict(&known, &ed25519(1), None, "db.internal", 0), Verdict::Trusted);
    }

    #[test]
    fn appending_makes_the_directory_and_refuses_a_relative_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".ssh").join("known_hosts");

        append(&path, "db.internal", &ed25519(1)).unwrap();

        assert!(path.is_file());
        assert!(append(Path::new("known_hosts"), "db.internal", &ed25519(1)).is_err());
    }

    #[test]
    fn forgetting_removes_only_the_hosts_plain_lines() {
        let (one, two) = (line(&ed25519(1)), line(&ed25519(2)));
        let contents =
            format!("# keep\ndb.internal {one}\n@revoked db.internal {two}\nweb.internal {one}\ndb.internal {ECDSA}\n");
        let (_dir, path) = known_file(&contents);

        forget_host(&path, "db.internal").unwrap();

        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            format!("# keep\n@revoked db.internal {two}\nweb.internal {one}\n")
        );
    }

    #[test]
    fn a_line_that_is_not_utf8_is_skipped_and_the_rest_still_read() {
        let key = line(&ed25519(1));
        let mut contents = b"# caf\xe9\n".to_vec();
        contents.extend(format!("@revoked db.internal {key}\nweb.internal {key}\n").as_bytes());
        let (_dir, path) = known_file("");
        fs::write(&path, &contents).unwrap();

        let known = read_known(&path, "db.internal").unwrap();
        forget_host(&path, "web.internal").unwrap();

        assert!(matches!(
            verdict(&known, &ed25519(1), None, "db.internal", 0),
            Verdict::Revoked { line: 2, .. }
        ));
        assert!(fs::read(&path).unwrap().starts_with(b"# caf\xe9\n@revoked"));
    }

    #[test]
    fn the_types_a_host_is_known_by_come_from_its_plain_lines() {
        let contents = format!(
            "db.internal {ECDSA}\n@revoked db.internal {}\ndb.internal {}\ndb.internal {ECDSA}\n",
            line(&ed25519(1)),
            line(&ed25519(2))
        );
        let (_dir, path) = known_file(&contents);

        let known = read_known(&path, "db.internal").unwrap();

        assert_eq!(
            known_types(&known),
            KnownTypes {
                plain: vec![ecdsa().algorithm(), Algorithm::Ed25519],
                authority: false,
            }
        );
        let (_dir, path) = known_file(&format!("@cert-authority *.internal {}\n", line(&ed25519(3))));
        assert!(known_types(&read_known(&path, "db.internal").unwrap()).authority);
    }

    #[test]
    fn wildcards_backtrack() {
        assert!(wildcard("*.*.com", "db.example.com"));
        assert!(wildcard("a*b*c", "aXbYbZc"));
        assert!(!wildcard("a*b*c", "aXbYbZ"));
        assert!(wildcard("*", ""));
        assert!(!wildcard("?", ""));
    }
}
