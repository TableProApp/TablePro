use std::collections::HashMap;

use uuid::Uuid;

mod close;
pub use close::{CloseAfterSave, close_other_page_indexes, close_page_indexes_to_right};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenMode {
    SwitchOrAppend,
    NewTab,
}

pub trait TabContent {
    fn table_target(&self) -> Option<(Option<&str>, &str)>;
}

struct Tab<T> {
    content: T,
    preview: bool,
}

pub struct WorkspaceTabs<T> {
    tabs: HashMap<Uuid, Tab<T>>,
}

impl<T> Default for WorkspaceTabs<T> {
    fn default() -> Self {
        Self { tabs: HashMap::new() }
    }
}

impl<T> WorkspaceTabs<T> {
    pub fn get(&self, id: &Uuid) -> Option<&T> {
        self.tabs.get(id).map(|tab| &tab.content)
    }

    pub fn get_mut(&mut self, id: &Uuid) -> Option<&mut T> {
        self.tabs.get_mut(id).map(|tab| &mut tab.content)
    }

    pub fn contains_key(&self, id: &Uuid) -> bool {
        self.tabs.contains_key(id)
    }

    pub fn keys(&self) -> impl Iterator<Item = &Uuid> {
        self.tabs.keys()
    }

    pub fn values(&self) -> impl Iterator<Item = &T> {
        self.tabs.values().map(|tab| &tab.content)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Uuid, &T)> {
        self.tabs.iter().map(|(id, tab)| (id, &tab.content))
    }

    pub fn is_empty(&self) -> bool {
        self.tabs.is_empty()
    }

    pub fn insert(&mut self, id: Uuid, content: T) -> Option<T> {
        self.tabs
            .insert(
                id,
                Tab {
                    content,
                    preview: false,
                },
            )
            .map(|tab| tab.content)
    }

    pub fn remove(&mut self, id: &Uuid) -> Option<T> {
        self.tabs.remove(id).map(|tab| tab.content)
    }

    pub fn is_preview(&self, id: &Uuid) -> bool {
        self.tabs.get(id).is_some_and(|tab| tab.preview)
    }

    pub fn keep(&mut self, id: &Uuid) -> bool {
        self.tabs
            .get_mut(id)
            .is_some_and(|tab| std::mem::replace(&mut tab.preview, false))
    }
}

impl<T: TabContent> WorkspaceTabs<T> {
    pub fn insert_with_preview(&mut self, id: Uuid, content: T, preview: bool) -> Option<T> {
        let preview = preview && content.table_target().is_some();
        self.tabs.insert(id, Tab { content, preview }).map(|tab| tab.content)
    }

    pub fn plan_table_open(
        &self,
        request: TableOpenRequest<'_>,
        has_pending_changes: impl Fn(Uuid) -> bool,
    ) -> TableOpenPlan {
        if request.mode == OpenMode::SwitchOrAppend {
            let matches = |tab: &T| tab.table_target() == Some((request.schema, request.table));
            let existing = request
                .selected
                .filter(|id| self.get(id).is_some_and(matches))
                .or_else(|| self.iter().find_map(|(id, tab)| matches(tab).then_some(*id)));
            if let Some(id) = existing {
                return TableOpenPlan::Select(id);
            }
        }
        let preview = opens_as_preview(request.mode == OpenMode::SwitchOrAppend, request.preview_enabled);
        let previous = if preview {
            self.tabs.iter().find_map(|(id, tab)| tab.preview.then_some(*id))
        } else {
            None
        };
        let (replace, promote) = match previous {
            Some(id) if has_pending_changes(id) => (None, Some(id)),
            Some(id) => (Some(id), None),
            None => (None, None),
        };
        TableOpenPlan::Append {
            preview,
            replace,
            promote,
        }
    }
}

pub struct TableOpenRequest<'a> {
    pub schema: Option<&'a str>,
    pub table: &'a str,
    pub selected: Option<Uuid>,
    pub mode: OpenMode,
    pub preview_enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableOpenPlan {
    Select(Uuid),
    Append {
        preview: bool,
        replace: Option<Uuid>,
        promote: Option<Uuid>,
    },
}

pub fn opens_as_preview(switch_or_append: bool, preview_tabs_enabled: bool) -> bool {
    switch_or_append && preview_tabs_enabled
}
