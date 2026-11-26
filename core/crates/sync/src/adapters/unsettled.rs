// What a connection copy an earlier iOS build wrote leaves unsaid, which the Swift engine settled against the record it
// last pulled (0054, Rules for both providers: each Swift rule is ported before its code goes). Such a copy holds
// Required where the Mac may hold Preferred, and no SSH profile link where the record has one, because that build never
// read the link. On iCloud each of these reads as the base's: it is no edit, so the push sends nothing over the Mac's
// value, and the pull that brings the record writes the base's value into the store with no approval to ask. The
// device marks such copies in two members it keeps to itself.

use std::collections::BTreeSet;

use serde_json::{Value, json};
use tablepro_records::Kind;

use super::fields::{get, set};
use super::library;

pub const TLS_MODE_UNSETTLED: &str = "tls_mode_unsettled";
pub const SSH_PROFILE_UNLINKED: &str = "ssh_profile_unlinked";
pub const ROUTE_PUBLISHER: &str = "route_publisher";

const MODE: &str = "/ssl_config/mode";
const PROFILE: &str = "/ssh_profile_id";

fn marked(copy: &Value, mark: &str) -> bool {
    copy.get(mark).and_then(Value::as_bool) == Some(true)
}

fn linked(copy: &Value) -> bool {
    get(Some(copy), PROFILE).is_some_and(|link| !link.is_null())
}

fn member<'a>(copy: &'a Value, pointer: &str) -> &'a Value {
    get(Some(copy), pointer).unwrap_or(&Value::Null)
}

// Where the tunnel dials, as `PublishedSSHRoute.Input` names it: the profile's password goes to the server a copy
// names, so a copy that names another one takes no link.
fn route(copy: &Value) -> Value {
    let hops: Vec<Value> = member(copy, "/ssh_config/jump_hosts")
        .as_array()
        .map(|hops| {
            hops.iter()
                .map(|hop| {
                    json!({
                        "id": member(hop, "/id"),
                        "host": member(hop, "/host"),
                        "port": member(hop, "/port"),
                        "username": member(hop, "/username"),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    json!({
        "host": member(copy, "/ssh_config/host"),
        "port": member(copy, "/ssh_config/port"),
        "username": member(copy, "/ssh_config/username"),
        "jump_hosts": hops,
    })
}

// The members of the store's copy that read as the base's.
pub fn at_base(kind: Kind, local: &Value, base: Option<&Value>) -> Vec<&'static str> {
    let mut pointers = Vec::new();
    let Some(base) = base.filter(|_| kind == Kind::Connection) else {
        return pointers;
    };
    // That build wrote Required for both, so either is what the copy says.
    if marked(local, TLS_MODE_UNSETTLED)
        && member(local, MODE).as_str() == Some("Required")
        && matches!(member(base, MODE).as_str(), Some("Preferred" | "Required"))
    {
        pointers.push(MODE);
    }
    // The Mac rebuilds a profile tunnel from the link alone, so a tunnel switched off drops it, and so does a link this
    // device removed.
    if !linked(local)
        && linked(base)
        && !marked(local, SSH_PROFILE_UNLINKED)
        && member(local, "/ssh_config/enabled").as_bool() == Some(true)
        && route(local) == route(base)
    {
        pointers.push(PROFILE);
    }
    pointers
}

// Every member of the store's copy that reads as the base's: what such a copy leaves unsaid, and what the store holds at
// the value this build reads the base's copy as (`library::at_base`).
pub fn reading(kind: Kind, local: &Value, base: Option<&Value>) -> Vec<String> {
    let mut pointers: Vec<String> = at_base(kind, local, base).into_iter().map(str::to_owned).collect();
    for pointer in library::at_base(kind, local, base) {
        if !pointers.contains(&pointer) {
            pointers.push(pointer);
        }
    }
    pointers
}

// The store's copy with those members at the base's value.
pub fn read(kind: Kind, local: &Value, base: Option<&Value>) -> Value {
    let mut read = local.clone();
    for pointer in reading(kind, local, base) {
        set(&mut read, &pointer, get(base, &pointer).cloned());
    }
    read
}

// The store's copy the approval queue judges a merge against: a member that reads as the base's counts as the base's
// value only where the merge kept the base's value, so nothing waits for a change nobody made. Where the server
// changed it, the store's own value stands, so a value this build reads its own way, such as a level a newer build
// added, never makes a looser pulled value look stricter than what the device enforces.
// A member that waits for the person or that the person refused stays at the store's value too, so a base that took
// a pulled value the person has not approved never stands in for the store's.
pub fn approval_view(
    kind: Kind,
    stored: &Value,
    base: Option<&Value>,
    merged: Option<&Value>,
    undecided: &BTreeSet<String>,
) -> Value {
    let mut view = stored.clone();
    let asked = |pointer: &str| {
        undecided.iter().any(|field| {
            field == pointer || pointer.starts_with(&format!("{field}/")) || field.starts_with(&format!("{pointer}/"))
        })
    };
    for pointer in reading(kind, stored, base) {
        if !asked(&pointer) && get(merged, &pointer) == get(base, &pointer) {
            set(&mut view, &pointer, get(base, &pointer).cloned());
        }
    }
    view
}

// What a pulled copy settles in the record the pull writes: the mode once the store holds the server's, and a removed
// link once the server's copy has none.
pub fn settle(kind: Kind, written: &mut Value, server: &Value) {
    if kind != Kind::Connection {
        return;
    }
    let mode_settled = marked(written, TLS_MODE_UNSETTLED)
        && !member(server, MODE).is_null()
        && member(written, MODE) == member(server, MODE);
    let unlink_settled = marked(written, SSH_PROFILE_UNLINKED) && !linked(server);
    let Some(members) = written.as_object_mut() else {
        return;
    };
    if mode_settled {
        members.remove(TLS_MODE_UNSETTLED);
    }
    if unlink_settled {
        members.remove(SSH_PROFILE_UNLINKED);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROFILE_ID: &str = "0F6C2A1E-6B3D-4D8E-9A51-3D7E2B1F0C44";

    fn tunnel(host: &str) -> Value {
        json!({
            "enabled": true,
            "host": host,
            "port": 22,
            "username": "deploy",
            "jump_hosts": [{"id": "hop", "host": "bastion", "port": 22, "username": "jump", "auth_method": "SSH Agent"}],
        })
    }

    fn linked_copy() -> Value {
        json!({"name": "prod", "ssh_config": tunnel("db.internal"), "ssh_profile_id": PROFILE_ID})
    }

    fn unlinked_copy() -> Value {
        json!({"name": "prod", "ssh_config": tunnel("db.internal")})
    }

    fn tls(mode: &str) -> Value {
        json!({"name": "prod", "ssl_config": {"mode": mode}})
    }

    fn unsettled(mode: &str) -> Value {
        let mut copy = tls(mode);
        copy[TLS_MODE_UNSETTLED] = json!(true);
        copy
    }

    #[test]
    fn an_unsettled_required_reads_as_the_base_s_preferred_or_required() {
        for base in ["Preferred", "Required"] {
            assert_eq!(
                read(Kind::Connection, &unsettled("Required"), Some(&tls(base)))["ssl_config"]["mode"],
                json!(base)
            );
        }
    }

    #[test]
    fn a_mode_stays_the_copy_s_unless_it_is_an_unsettled_required_against_preferred_or_required() {
        let cases = [
            (tls("Required"), tls("Preferred")),
            (unsettled("Verify CA"), tls("Preferred")),
            (unsettled("Required"), tls("Verify Identity")),
            (unsettled("Required"), json!({"name": "prod"})),
        ];
        for (local, base) in cases {
            assert!(
                at_base(Kind::Connection, &local, Some(&base)).is_empty(),
                "{local} over {base}"
            );
        }
        assert!(at_base(Kind::Connection, &unsettled("Required"), None).is_empty());
    }

    #[test]
    fn a_missing_link_reads_as_the_base_s_while_the_tunnel_is_on_and_dials_the_same_server() {
        let read = read(Kind::Connection, &unlinked_copy(), Some(&linked_copy()));

        assert_eq!(read["ssh_profile_id"], json!(PROFILE_ID));
        assert_eq!(read["ssh_config"], unlinked_copy()["ssh_config"]);
    }

    #[test]
    fn a_link_stays_removed_when_the_tunnel_is_off_the_device_removed_it_or_the_copy_dials_elsewhere() {
        let mut off = unlinked_copy();
        off["ssh_config"]["enabled"] = json!(false);
        let mut removed = unlinked_copy();
        removed[SSH_PROFILE_UNLINKED] = json!(true);
        let elsewhere = json!({"name": "prod", "ssh_config": tunnel("db.example.com")});
        let mut other_hop = unlinked_copy();
        other_hop["ssh_config"]["jump_hosts"][0]["host"] = json!("other-bastion");

        for local in [off, removed, elsewhere, other_hop] {
            assert!(
                at_base(Kind::Connection, &local, Some(&linked_copy())).is_empty(),
                "{local}"
            );
        }
        assert!(at_base(Kind::Connection, &unlinked_copy(), Some(&unlinked_copy())).is_empty());
    }

    #[test]
    fn a_hop_s_sign_in_is_not_where_the_tunnel_dials() {
        let mut agent = unlinked_copy();
        agent["ssh_config"]["jump_hosts"][0]["auth_method"] = json!("Private Key");

        assert_eq!(at_base(Kind::Connection, &agent, Some(&linked_copy())), vec![PROFILE]);
    }

    #[test]
    fn a_copy_with_a_link_of_its_own_keeps_it() {
        let mut own = linked_copy();
        own["ssh_profile_id"] = json!("8D1B0C2A-0000-4000-8000-000000000001");

        assert!(at_base(Kind::Connection, &own, Some(&linked_copy())).is_empty());
    }

    #[test]
    fn only_connections_read_against_the_base() {
        let mut group = unsettled("Required");
        group[SSH_PROFILE_UNLINKED] = json!(false);

        assert!(at_base(Kind::Group, &group, Some(&tls("Preferred"))).is_empty());
    }

    #[test]
    fn a_pull_settles_the_mode_once_the_store_holds_the_server_s() {
        let mut settled = unsettled("Preferred");
        settle(Kind::Connection, &mut settled, &tls("Preferred"));
        let mut differs = unsettled("Required");
        settle(Kind::Connection, &mut differs, &tls("Preferred"));
        let mut no_mode = unsettled("Required");
        settle(Kind::Connection, &mut no_mode, &json!({"name": "prod"}));

        assert_eq!(settled, tls("Preferred"));
        assert!(marked(&differs, TLS_MODE_UNSETTLED));
        assert!(marked(&no_mode, TLS_MODE_UNSETTLED));
    }

    #[test]
    fn a_pull_settles_a_removed_link_once_the_server_s_copy_has_none() {
        let mut removed = unlinked_copy();
        removed[SSH_PROFILE_UNLINKED] = json!(true);
        let mut kept = removed.clone();

        settle(Kind::Connection, &mut removed, &unlinked_copy());
        settle(Kind::Connection, &mut kept, &linked_copy());

        assert_eq!(removed, unlinked_copy());
        assert!(marked(&kept, SSH_PROFILE_UNLINKED));
    }
}
