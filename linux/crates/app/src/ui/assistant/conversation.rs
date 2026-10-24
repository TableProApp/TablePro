use tablepro_ai::{Action, ChatMessage, ChatRequest};

/// What the user asked in one turn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Asked {
    Typed(String),
    Action {
        action: Action,
        statement: String,
        error: Option<String>,
    },
}

impl Asked {
    /// The message the provider receives.
    pub(crate) fn message(&self) -> String {
        match self {
            Self::Typed(text) => text.clone(),
            Self::Action {
                action,
                statement,
                error,
            } => tablepro_ai::action_message(*action, statement, error.as_deref()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Turn {
    pub asked: Asked,
    /// `None` until a reply ends; a failed one never gets one.
    pub answer: Option<String>,
}

/// The turns of one conversation, sent whole with each new question.
/// The system prompt is set when it starts and never changes after.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Conversation {
    system: String,
    turns: Vec<Turn>,
}

impl Conversation {
    pub(crate) fn new(system: String) -> Self {
        Self {
            system,
            turns: Vec::new(),
        }
    }

    pub(crate) fn ask(&mut self, asked: Asked) {
        self.turns.push(Turn { asked, answer: None });
    }

    /// The reply to the last question, or what came of it before Stop.
    pub(crate) fn answer(&mut self, text: String) {
        if let Some(turn) = self.turns.last_mut() {
            turn.answer = Some(text);
        }
    }

    /// The request for the last question. A turn that got no answer is
    /// left out, so the provider sees questions and answers in turn.
    pub(crate) fn request(&self, max_tokens: u32) -> ChatRequest {
        let mut messages = Vec::new();
        let last = self.turns.len().saturating_sub(1);
        for (index, turn) in self.turns.iter().enumerate() {
            if index == last {
                messages.push(ChatMessage::user(turn.asked.message()));
                break;
            }
            if let Some(answer) = turn.answer.as_ref().filter(|answer| !answer.trim().is_empty()) {
                messages.push(ChatMessage::user(turn.asked.message()));
                messages.push(ChatMessage::assistant(answer.clone()));
            }
        }
        ChatRequest {
            system: self.system.clone(),
            messages,
            max_tokens,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_ai::Role;

    use super::*;

    #[test]
    fn each_question_carries_the_answered_turns_before_it() {
        let mut conversation = Conversation::new("system".to_owned());
        conversation.ask(Asked::Typed("first".to_owned()));
        conversation.answer("one".to_owned());
        conversation.ask(Asked::Typed("lost".to_owned()));
        conversation.ask(Asked::Typed("second".to_owned()));

        let request = conversation.request(100);

        let roles: Vec<Role> = request.messages.iter().map(|message| message.role).collect();
        let texts: Vec<&str> = request.messages.iter().map(|message| message.text.as_str()).collect();
        assert_eq!(request.system, "system");
        assert_eq!(roles, [Role::User, Role::Assistant, Role::User]);
        assert_eq!(texts, ["first", "one", "second"]);
    }

    #[test]
    fn an_action_sends_its_question_with_the_statement() {
        let mut conversation = Conversation::new(String::new());
        conversation.ask(Asked::Action {
            action: Action::Fix,
            statement: "SELEC 1".to_owned(),
            error: Some("syntax error".to_owned()),
        });

        let request = conversation.request(100);

        assert!(request.messages[0].text.contains("SELEC 1"));
        assert!(request.messages[0].text.contains("syntax error"));
    }
}
