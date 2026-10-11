use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Decision {
    Allow {
        rule: String,
    },
    RequireApproval {
        rule: String,
        reason: String,
        preview: Option<String>,
    },
    Deny {
        rule: String,
        message: String,
    },
}

impl Decision {
    pub fn rule_name(&self) -> &str {
        match self {
            Self::Allow { rule } | Self::RequireApproval { rule, .. } | Self::Deny { rule, .. } => rule,
        }
    }

    pub fn is_allow(&self) -> bool {
        matches!(self, Self::Allow { .. })
    }

    fn severity(&self) -> u8 {
        match self {
            Self::Allow { .. } => 0,
            Self::RequireApproval { .. } => 1,
            Self::Deny { .. } => 2,
        }
    }

    pub(crate) fn join_all(decisions: impl IntoIterator<Item = Self>) -> Option<Self> {
        let mut decisions: Vec<Self> = decisions.into_iter().collect();
        let severity = decisions.iter().map(Self::severity).max()?;
        decisions.retain(|decision| decision.severity() == severity);
        decisions.sort_by_key(|decision| (decision.rule_name().to_owned(), decision_detail(decision)));
        decisions.dedup();
        if decisions.len() == 1 {
            return decisions.pop();
        }

        let mut rules = decisions.iter().map(Self::rule_name).collect::<Vec<_>>();
        rules.dedup();
        let rule = rules.join("+");
        match severity {
            0 => Some(Self::Allow { rule }),
            1 => {
                let reason = decisions
                    .iter()
                    .filter_map(|decision| match decision {
                        Self::RequireApproval { reason, .. } => Some(reason.as_str()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                let preview = decisions.iter().find_map(|decision| match decision {
                    Self::RequireApproval { preview, .. } => preview.clone(),
                    _ => None,
                });
                Some(Self::RequireApproval { rule, reason, preview })
            }
            _ => {
                let message = decisions
                    .iter()
                    .filter_map(|decision| match decision {
                        Self::Deny { message, .. } => Some(message.as_str()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                Some(Self::Deny { rule, message })
            }
        }
    }
}

fn decision_detail(decision: &Decision) -> String {
    match decision {
        Decision::Allow { .. } => String::new(),
        Decision::RequireApproval { reason, preview, .. } => format!("{reason}:{preview:?}"),
        Decision::Deny { message, .. } => message.clone(),
    }
}
