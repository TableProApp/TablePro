//! MCP pairing / token issuance page for Preferences.

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use std::sync::Arc;

use tablepro_mcp::{McpBridge, TokenPermissions};

use crate::services::mcp_service;
use crate::tr;

pub fn build_page(
    database: &crate::services::database_service::DatabaseService,
    mcp_bridge: Option<Arc<McpBridge>>,
) -> adw::PreferencesPage {
    let policy_reload = database.reload_policy();

    let page = adw::PreferencesPage::builder()
        .title(tr!("MCP"))
        .icon_name("network-server-symbolic")
        .build();

    let status_group = adw::PreferencesGroup::builder()
        .title(tr!("Agent access"))
        .description(tr!(
            "Loopback MCP server on 127.0.0.1:17432. Tokens gate which connections agents may use."
        ))
        .build();

    if let Err(error) = policy_reload {
        tracing::warn!(error = %error, "policy reload failed; keeping the previous policy");
        let row = adw::ActionRow::builder()
            .title(tr!("Policy file could not be reloaded"))
            .subtitle(tr!(
                "The previous policy is still in use. Fix the policy file and reopen Preferences."
            ))
            .build();
        status_group.add(&row);
    }

    let endpoint_row = adw::ActionRow::builder()
        .title(tr!("Endpoint"))
        .subtitle("http://127.0.0.1:17432/mcp")
        .build();
    status_group.add(&endpoint_row);

    let issue_group = adw::PreferencesGroup::builder()
        .title(tr!("Issue token"))
        .description(tr!(
            "Plaintext is shown once and stored in the system keyring. Agents send it as a Bearer token."
        ))
        .build();

    let name_row = adw::EntryRow::builder().title(tr!("Client name")).build();
    name_row.set_text("Cursor");

    let scope_combo = adw::ComboRow::builder().title(tr!("Scope")).build();
    let scope_model = gtk::StringList::new(&["Read only", "Read and write"]);
    scope_combo.set_model(Some(&scope_model));
    scope_combo.set_selected(0);

    let issue_button = gtk::Button::builder()
        .label(tr!("Issue token"))
        .valign(gtk::Align::Center)
        .build();
    issue_button.add_css_class("suggested-action");
    let issue_row = adw::ActionRow::builder().title(tr!("Create pairing token")).build();
    issue_row.add_suffix(&issue_button);

    issue_group.add(&name_row);
    issue_group.add(&scope_combo);
    issue_group.add(&issue_row);

    let tokens_group = adw::PreferencesGroup::builder().title(tr!("Active tokens")).build();
    refresh_token_list(&tokens_group, mcp_bridge.clone());

    let name_for_issue = name_row.clone();
    let scope_for_issue = scope_combo.clone();
    let tokens_for_issue = tokens_group.clone();
    let page_for_dialog = page.clone();
    let bridge_for_issue = mcp_bridge.clone();
    issue_button.connect_clicked(move |_| {
        let name = name_for_issue.text().to_string();
        if name.trim().is_empty() {
            return;
        }
        let permissions = match scope_for_issue.selected() {
            1 => TokenPermissions::ReadWrite,
            _ => TokenPermissions::ReadOnly,
        };
        let tokens_group = tokens_for_issue.clone();
        let parent = page_for_dialog.clone();
        let bridge = bridge_for_issue.clone();
        glib::spawn_future_local(async move {
            let allowlist = match tablepro_storage::load_connections().await {
                Ok(list) => list.into_iter().map(|c| c.id).collect::<Vec<_>>(),
                Err(e) => {
                    let msg = format!("could not load connections: {e}");
                    let alert = adw::AlertDialog::new(
                        Some(&tr!("Could not issue token")),
                        Some(&msg),
                    );
                    alert.add_response("ok", &tr!("OK"));
                    alert.set_default_response(Some("ok"));
                    alert.present(Some(&parent));
                    return;
                }
            };
            if allowlist.is_empty() {
                let alert = adw::AlertDialog::new(
                    Some(&tr!("Could not issue token")),
                    Some(&tr!(
                        "Save at least one connection before issuing an MCP token. Tokens are scoped to the connections that exist at issue time."
                    )),
                );
                alert.add_response("ok", &tr!("OK"));
                alert.set_default_response(Some("ok"));
                alert.present(Some(&parent));
                return;
            }
            match mcp_service::issue_token(bridge.as_ref(), name, permissions, allowlist).await {
                Ok((_id, plaintext)) => {
                    show_issued_token(&parent, &plaintext);
                    clear_and_refresh(&tokens_group, bridge.clone());
                }
                Err(e) => {
                    tracing::warn!(error = %e, "MCP token issue failed");
                    let alert = adw::AlertDialog::new(
                        Some(&tr!("Could not issue token")),
                        Some(&e),
                    );
                    alert.add_response("ok", &tr!("OK"));
                    alert.set_default_response(Some("ok"));
                    alert.present(Some(&parent));
                }
            }
        });
    });

    page.add(&status_group);
    page.add(&issue_group);
    page.add(&tokens_group);
    page
}

fn clear_and_refresh(group: &adw::PreferencesGroup, mcp_bridge: Option<Arc<McpBridge>>) {
    while let Some(child) = group.first_child() {
        group.remove(&child);
    }
    refresh_token_list(group, mcp_bridge);
}

fn refresh_token_list(group: &adw::PreferencesGroup, mcp_bridge: Option<Arc<McpBridge>>) {
    let tokens = mcp_service::list_tokens(mcp_bridge.as_ref());
    if tokens.is_empty() {
        let empty = adw::ActionRow::builder()
            .title(tr!("No tokens yet"))
            .subtitle(tr!("Issue a token above to pair an MCP client."))
            .build();
        group.add(&empty);
        return;
    }
    for token in tokens {
        if token.revoked {
            continue;
        }
        let row = adw::ActionRow::builder()
            .title(&token.name)
            .subtitle(format!(
                "{} · {}",
                permissions_label(token.permissions),
                token.created_at.format("%Y-%m-%d")
            ))
            .build();
        let revoke = gtk::Button::builder()
            .label(tr!("Revoke"))
            .valign(gtk::Align::Center)
            .build();
        revoke.add_css_class("destructive-action");
        revoke.add_css_class("flat");
        let id = token.id;
        let group_c = group.clone();
        let bridge_for_revoke = mcp_bridge.clone();
        revoke.connect_clicked(move |_| {
            if let Err(e) = mcp_service::revoke_token(bridge_for_revoke.as_ref(), id) {
                tracing::warn!(error = %e, "revoke failed");
            }
            clear_and_refresh(&group_c, bridge_for_revoke.clone());
        });
        row.add_suffix(&revoke);
        group.add(&row);
    }
}

fn permissions_label(p: TokenPermissions) -> &'static str {
    match p {
        TokenPermissions::ReadOnly => "read-only",
        TokenPermissions::ReadWrite => "read-write",
    }
}

fn show_issued_token(parent: &impl IsA<gtk::Widget>, plaintext: &str) {
    let alert = adw::AlertDialog::new(
        Some(&tr!("Token issued")),
        Some(&format!(
            "{}\n\n{}\n\n{}",
            tr!("Copy this token now. It will not be shown again in the UI."),
            plaintext,
            tr!("Endpoint: http://127.0.0.1:17432/mcp")
        )),
    );
    alert.add_response("ok", &tr!("Done"));
    alert.set_default_response(Some("ok"));
    alert.present(Some(parent));
}
