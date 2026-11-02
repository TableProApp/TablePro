use secrecy::SecretString;

#[derive(Debug)]
pub enum PromptReply {
    Submitted { values: Vec<SecretString>, remember: bool },
    Cancelled,
}
