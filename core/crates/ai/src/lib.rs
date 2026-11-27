//! The AI assistant's providers: Anthropic's Messages API and the OpenAI
//! Chat Completions protocol, which OpenAI and Ollama speak. Free of GTK;
//! the app decides what a prompt may carry and asks the user first.

mod ai_error;
mod anthropic;
mod catalog;
mod chat_request;
mod completion;
mod endpoint;
mod http_client;
mod key_vault;
mod model_list;
mod model_merge;
mod openai;
mod prompt;
mod protocol;
mod reply;
mod reply_stream;
mod schema_context;

pub use ai_error::AiError;
pub use catalog::{
    Api, Catalog, CatalogError, CatalogModel, ModelCatalog, ProviderCatalog, REFRESH_URL, SCHEMA_VERSION,
};
pub use chat_request::{ChatMessage, ChatRequest, ContentBlock, Role, ToolSpec};
pub use completion::clean_completion;
pub use endpoint::Endpoint;
pub use http_client::AiClient;
pub use key_vault::ApiKeyVault;
pub use model_list::list_models;
pub use model_merge::{LiveModel, MergeRules, ModelInfo, merge_models};
pub use prompt::{
    Action, MAX_DESCRIBED_TABLES, action_message, chat_system_prompt, completion_message, completion_system_prompt,
};
pub use reply::{ReplyEnd, ReplyEvent, StopReason, Usage};
pub use reply_stream::{collect_reply, stream_reply};
pub use schema_context::{ColumnShape, QueryLanguage, SchemaContext, TableShape};
