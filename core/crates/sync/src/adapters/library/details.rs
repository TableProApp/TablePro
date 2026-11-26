// The route a Mac dialed for a tunnel (`PublishedSSHRoute`, ids in upper case) and a password kept elsewhere (0044,
// Typed references), as their wire members name them.

use serde_json::Value;
use tablepro_storage::{CredentialReference, SshRoute, SshRouteHop, SshRouteTarget, VaultAuth, VaultDatabaseRole};

use super::values::{Object, clamped, integer, text, uuid, uuid_value};

fn endpoint(alias: &str, host: &str, port: u16, username: &str) -> Object {
    let mut out = Object::default();
    out.put("alias", alias)
        .put("host", host)
        .put("port", port)
        .put("username", username);
    out
}

pub(super) fn route_to_wire(route: &SshRoute) -> Value {
    let hops: Vec<Value> = route
        .hops
        .iter()
        .map(|hop| {
            endpoint(&hop.alias, &hop.host, hop.port, &hop.username)
                .put("id", uuid_value(hop.id))
                .done()
        })
        .collect();
    let target = &route.target;
    Object::default()
        .put("basis", route.basis.as_str())
        .put("hops", hops)
        .put("publisher", uuid_value(route.publisher))
        .put(
            "target",
            endpoint(&target.alias, &target.host, target.port, &target.username).done(),
        )
        .put("version", route.version)
        .done()
}

fn owned(fields: &Value, key: &str) -> String {
    text(fields, key).unwrap_or_default().to_owned()
}

fn port(fields: &Value) -> u16 {
    integer(fields, "port").map_or(0, clamped)
}

// A route whose publisher is no UUID is no route, and a hop whose id is none is left out, as the Mac reads them.
pub(super) fn route_from_wire(fields: &Value) -> Option<SshRoute> {
    let target = fields.get("target").unwrap_or(&Value::Null);
    Some(SshRoute {
        version: integer(fields, "version").map_or(0, clamped),
        publisher: uuid(text(fields, "publisher"))?,
        basis: owned(fields, "basis"),
        hops: fields
            .get("hops")
            .and_then(Value::as_array)
            .map(|hops| {
                hops.iter()
                    .filter_map(|hop| {
                        Some(SshRouteHop {
                            id: uuid(text(hop, "id"))?,
                            alias: owned(hop, "alias"),
                            host: owned(hop, "host"),
                            port: port(hop),
                            username: owned(hop, "username"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
        target: SshRouteTarget {
            alias: owned(target, "alias"),
            host: owned(target, "host"),
            port: port(target),
            username: owned(target, "username"),
        },
        unknown: std::collections::BTreeMap::new(),
    })
}

// `PublishedSSHRoute.leadsToSameHosts`: the same version and basis, through the same hosts, ports and users.
pub(super) fn same_hosts(left: &Value, right: &Value) -> bool {
    let (Some(left), Some(right)) = (route_from_wire(left), route_from_wire(right)) else {
        return false;
    };
    let hops = |route: &SshRoute| -> Vec<(String, u16, String)> {
        route
            .hops
            .iter()
            .map(|hop| (hop.host.clone(), hop.port, hop.username.clone()))
            .collect()
    };
    let target = |route: &SshRoute| {
        (
            route.target.host.clone(),
            route.target.port,
            route.target.username.clone(),
        )
    };
    left.version == right.version
        && left.basis == right.basis
        && hops(&left) == hops(&right)
        && target(&left) == target(&right)
}

pub(super) fn reference_to_wire(reference: &CredentialReference) -> Value {
    let mut out = Object::default();
    match reference {
        CredentialReference::Env { variable } => {
            out.put("kind", "env").put("variable", variable.as_str());
        }
        CredentialReference::OnePassword { reference } => {
            out.put("kind", "onePassword").put("reference", reference.as_str());
        }
        CredentialReference::Vault { path, field } => {
            out.put("kind", "vault")
                .put("path", path.as_str())
                .put("field", field.as_str());
        }
        CredentialReference::AwsSecretsManager { secret_id, json_key } => {
            out.put("kind", "awsSecretsManager")
                .put("secret_id", secret_id.as_str())
                .put_some("json_key", json_key.as_deref());
        }
        CredentialReference::VaultDatabaseRole(role) => {
            out.put("kind", "vaultDatabaseRole")
                .put_some("address", role.address.as_deref())
                .put("mount", role.mount.as_str())
                .put("role", role.role.as_str())
                .put("auth", vault_auth_to_wire(&role.auth));
        }
    }
    out.done()
}

fn vault_auth_to_wire(auth: &VaultAuth) -> Value {
    let mut out = Object::default();
    match auth {
        VaultAuth::Token => {
            out.put("method", "token");
        }
        VaultAuth::AppRole {
            mount,
            role_id,
            secret_id_path,
        } => {
            out.put("method", "approle")
                .put("mount", mount.as_str())
                .put("role_id", role_id.as_str())
                .put("secret_id_path", secret_id_path.to_string_lossy().into_owned());
        }
        VaultAuth::Oidc { mount, role } => {
            out.put("method", "oidc")
                .put("mount", mount.as_str())
                .put("role", role.as_str());
        }
    }
    out.done()
}

// A kind or a sign-in a newer build added is no reference this build can resolve, so the connection has none.
pub(super) fn reference_from_wire(fields: &Value) -> Option<CredentialReference> {
    Some(match text(fields, "kind")? {
        "env" => CredentialReference::Env {
            variable: owned(fields, "variable"),
        },
        "onePassword" => CredentialReference::OnePassword {
            reference: owned(fields, "reference"),
        },
        "vault" => CredentialReference::Vault {
            path: owned(fields, "path"),
            field: owned(fields, "field"),
        },
        "awsSecretsManager" => CredentialReference::AwsSecretsManager {
            secret_id: owned(fields, "secret_id"),
            json_key: text(fields, "json_key").map(str::to_owned),
        },
        "vaultDatabaseRole" => {
            let auth = fields.get("auth").unwrap_or(&Value::Null);
            CredentialReference::VaultDatabaseRole(VaultDatabaseRole {
                address: text(fields, "address").map(str::to_owned),
                mount: owned(fields, "mount"),
                role: owned(fields, "role"),
                auth: match text(auth, "method")? {
                    "token" => VaultAuth::Token,
                    "approle" => VaultAuth::AppRole {
                        mount: owned(auth, "mount"),
                        role_id: owned(auth, "role_id"),
                        secret_id_path: owned(auth, "secret_id_path").into(),
                    },
                    "oidc" => VaultAuth::Oidc {
                        mount: owned(auth, "mount"),
                        role: owned(auth, "role"),
                    },
                    _ => return None,
                },
            })
        }
        _ => return None,
    })
}
