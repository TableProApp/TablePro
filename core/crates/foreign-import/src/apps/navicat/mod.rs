mod cipher;

use std::collections::BTreeMap;
use std::path::PathBuf;

use roxmltree::{Document, Node};
use secrecy::SecretString;
use tokio_util::sync::CancellationToken;

use crate::app::{AppReader, check_cancel};
use crate::apps::resolve_key_path;
use crate::collect::assemble;
use crate::{
    CollectedImport, ForeignApp, ForeignConnection, ForeignConnectionRecord, ForeignCredentials, ForeignImportError,
    ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode, ImportRequest, Inventory, PasswordOutcome, engine,
};

pub(crate) struct Navicat {
    file: Option<PathBuf>,
}

impl Navicat {
    pub(crate) fn new(file: Option<PathBuf>) -> Self {
        Self { file }
    }

    fn read(&self) -> Result<String, ForeignImportError> {
        let not_found = || ForeignImportError::FileNotFound {
            app: ForeignApp::Navicat,
        };
        let path = self.file.as_ref().ok_or_else(not_found)?;
        let data = crate::files::read_capped(path).map_err(|_| not_found())?;
        String::from_utf8(data).map_err(|_| ForeignImportError::parse("the export is not UTF-8 text"))
    }
}

impl AppReader for Navicat {
    fn has_data(&self) -> bool {
        self.file.is_some()
    }

    fn inventory(&self) -> Inventory {
        let connections = self
            .read()
            .ok()
            .and_then(|text| parse(&text).ok().map(|document| connection_elements(&document).count()))
            .unwrap_or(0);
        Inventory {
            connections,
            saved_queries: 0,
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let text = self.read()?;
        let document = parse(&text)?;
        let mut records = Vec::new();
        for element in connection_elements(&document) {
            check_cancel(cancel)?;
            records.push(ForeignConnectionRecord {
                source_id: None,
                settings: connection(element),
                group_path: Vec::new(),
                credentials: if request.include_passwords {
                    credentials(element)
                } else {
                    None
                },
            });
        }
        let passwords = if request.include_passwords {
            PasswordOutcome::Read
        } else {
            PasswordOutcome::NotRequested
        };
        assemble(ForeignApp::Navicat, records, Vec::new(), passwords)
    }
}

// The default options refuse a document type, so no entity of any kind is expanded.
fn parse(text: &str) -> Result<Document<'_>, ForeignImportError> {
    Document::parse(text).map_err(|error| ForeignImportError::parse(error.to_string()))
}

// Every `Connection` element at any depth, as the XPath `//Connection` selects.
fn connection_elements<'a, 'input>(document: &'a Document<'input>) -> impl Iterator<Item = Node<'a, 'input>> {
    document.descendants().filter(|node| {
        node.is_element() && node.tag_name().name() == "Connection" && node.tag_name().namespace().is_none()
    })
}

fn connection(element: Node<'_, '_>) -> ForeignConnection {
    let engine = engine_name(attribute(element, "ConnType"));
    let is_file_based = engine == "SQLite";
    let port = if is_file_based {
        0
    } else {
        attribute(element, "Port")
            .parse::<i64>()
            .ok()
            .and_then(|port| u16::try_from(port).ok())
            .unwrap_or_else(|| engine::default_port(&engine))
    };
    ForeignConnection {
        name: non_empty(attribute(element, "ConnectionName"))
            .unwrap_or("Navicat")
            .to_owned(),
        host: if is_file_based {
            String::new()
        } else {
            non_empty(attribute(element, "Host")).unwrap_or("localhost").to_owned()
        },
        port,
        database: attribute(element, if is_file_based { "DatabaseFileName" } else { "Database" }).to_owned(),
        username: if is_file_based {
            String::new()
        } else {
            attribute(element, "UserName").to_owned()
        },
        ssh: ssh(element),
        ssl: ssl(element),
        color: None,
        additional_fields: BTreeMap::new(),
        engine,
    }
}

fn ssh(element: Node<'_, '_>) -> Option<ForeignSsh> {
    if !is_true(attribute(element, "SSH")) {
        return None;
    }
    let uses_key = attribute(element, "SSH_AuthenMethod").to_uppercase() != "PASSWORD";
    Some(ForeignSsh {
        host: attribute(element, "SSH_Host").to_owned(),
        port: attribute(element, "SSH_Port")
            .parse::<i64>()
            .ok()
            .and_then(|port| u16::try_from(port).ok()),
        username: attribute(element, "SSH_UserName").to_owned(),
        auth: if uses_key {
            ForeignSshAuth::PrivateKey
        } else {
            ForeignSshAuth::Password
        },
        private_key_path: if uses_key {
            resolve_key_path(attribute(element, "SSH_PrivateKey"))
        } else {
            String::new()
        },
        jump_hosts: Vec::new(),
    })
}

fn ssl(element: Node<'_, '_>) -> Option<ForeignSsl> {
    if !is_true(attribute(element, "SSL")) {
        return None;
    }
    let path = |name: &str| non_empty(attribute(element, name)).map(str::to_owned);
    Some(ForeignSsl {
        mode: ssl_mode(attribute(element, "SSL_PGSSLMode")),
        ca_certificate_path: path("SSL_CACert"),
        client_certificate_path: path("SSL_ClientCert"),
        client_key_path: path("SSL_ClientKey"),
    })
}

fn credentials(element: Node<'_, '_>) -> Option<ForeignCredentials> {
    let saved = |flag: &str, field: &str| {
        if is_true(attribute(element, flag)) {
            decrypt_field(attribute(element, field))
        } else {
            None
        }
    };
    let password = saved("SavePassword", "Password");
    let ssh_password = saved("SSH_SavePassword", "SSH_Password");
    // The macOS port left a saved key passphrase behind; the export spells it in either case.
    let key_passphrase = if is_true(attribute_any_case(element, "SSH_SavePassPhrase")) {
        decrypt_field(attribute_any_case(element, "SSH_PassPhrase"))
    } else {
        None
    };
    ForeignCredentials {
        password,
        ssh_password,
        key_passphrase,
    }
    .non_empty()
}

fn decrypt_field(hex: &str) -> Option<SecretString> {
    let trimmed = hex.trim();
    if trimmed.is_empty() {
        return None;
    }
    match cipher::decrypt(trimmed) {
        Some(value) => Some(SecretString::from(value)),
        None => {
            tracing::warn!("could not decrypt a Navicat password field");
            None
        }
    }
}

fn engine_name(raw: &str) -> String {
    match raw.to_uppercase().as_str() {
        "MYSQL" => "MySQL".to_owned(),
        "MARIADB" => "MariaDB".to_owned(),
        "POSTGRESQL" => "PostgreSQL".to_owned(),
        "ORACLE" => "Oracle".to_owned(),
        "SQLITE" => "SQLite".to_owned(),
        "SQLSERVER" => "SQL Server".to_owned(),
        "MONGODB" => "MongoDB".to_owned(),
        _ => engine::resolve(raw),
    }
}

fn ssl_mode(raw: &str) -> ForeignSslMode {
    match raw.to_uppercase().as_str() {
        "VERIFY-CA" => ForeignSslMode::VerifyCa,
        "VERIFY-FULL" => ForeignSslMode::VerifyIdentity,
        "PREFER" | "ALLOW" => ForeignSslMode::Preferred,
        _ => ForeignSslMode::Required,
    }
}

fn attribute<'a>(element: Node<'a, '_>, name: &str) -> &'a str {
    element.attribute(name).unwrap_or_default()
}

fn attribute_any_case<'a>(element: Node<'a, '_>, name: &str) -> &'a str {
    element
        .attributes()
        .find(|attribute| attribute.name().eq_ignore_ascii_case(name))
        .map_or("", |attribute| attribute.value())
}

fn is_true(value: &str) -> bool {
    value.to_lowercase() == "true"
}

fn non_empty(value: &str) -> Option<&str> {
    (!value.is_empty()).then_some(value)
}
