use std::collections::HashMap;

use super::*;
use tablepro_app_services::completion_proposals::Candidates;

struct Data {
    candidates: Candidates,
    source: Rc<str>,
    cursor: i32,
    request: SchemaRequest,
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct ProposalModel {
        pub(super) data: OnceCell<Data>,
        pub(super) cache: RefCell<HashMap<u32, Proposal>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ProposalModel {
        const NAME: &str = "BookieSqlCompletionModel";
        type Type = super::ProposalModel;
        type Interfaces = (gio::ListModel,);
    }

    impl ObjectImpl for ProposalModel {}

    impl gio::subclass::prelude::ListModelImpl for ProposalModel {
        fn item_type(&self) -> glib::Type {
            Proposal::static_type()
        }

        fn n_items(&self) -> u32 {
            self.data.get().map_or(0, |data| data.candidates.values.len() as u32)
        }

        fn item(&self, position: u32) -> Option<glib::Object> {
            if let Some(proposal) = self.cache.borrow().get(&position) {
                return Some(proposal.clone().upcast());
            }
            let data = self.data.get()?;
            let (label, sql) = data.candidates.values.get(position as usize)?;
            let proposal: Proposal = glib::Object::new();
            let _ = proposal.imp().insertion.set(Insertion {
                label: label.clone(),
                sql: sql.clone(),
                source: data.source.clone(),
                cursor: data.cursor,
                range: data.candidates.range.clone(),
                request: SchemaRequest {
                    generation: data.request.generation,
                    table: data.request.table.clone(),
                },
            });
            self.cache.borrow_mut().insert(position, proposal.clone());
            Some(proposal.upcast())
        }
    }
}

glib::wrapper! {
    pub struct ProposalModel(ObjectSubclass<imp::ProposalModel>) @implements gio::ListModel;
}

impl ProposalModel {
    pub(super) fn new(candidates: Candidates, source: Rc<str>, cursor: i32, request: SchemaRequest) -> Self {
        let model: Self = glib::Object::new();
        let _ = model.imp().data.set(Data {
            candidates,
            source,
            cursor,
            request,
        });
        model
    }
}
