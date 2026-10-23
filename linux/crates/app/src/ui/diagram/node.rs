use std::cell::Cell;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct DiagramNode {
        pub(super) index: Cell<usize>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DiagramNode {
        const NAME: &'static str = "TableProDiagramNode";
        type Type = super::DiagramNode;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("tp-diagram-node");
            klass.set_accessible_role(gtk::AccessibleRole::ListItem);
        }
    }

    impl ObjectImpl for DiagramNode {
        fn constructed(&self) {
            self.parent_constructed();
            let node = self.obj();
            node.set_focusable(true);
            // The canvas reads the pointer itself, so a press lands on it
            // whatever card is under the pointer.
            node.set_can_target(false);
        }
    }

    impl WidgetImpl for DiagramNode {}
}

glib::wrapper! {
    /// One table of the diagram as the keyboard and a screen reader meet
    /// it. The canvas draws the card; this widget sits where the card is,
    /// takes the focus, and carries the table's name and description, so
    /// Tab, the arrow keys and Orca move from table to table the way they
    /// move between any widgets.
    pub struct DiagramNode(ObjectSubclass<imp::DiagramNode>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl DiagramNode {
    pub(crate) fn new(index: usize, label: &str, description: &str, count: usize) -> Self {
        let node: Self = glib::Object::new();
        node.imp().index.set(index);
        node.update_property(&[
            gtk::accessible::Property::Label(label),
            gtk::accessible::Property::Description(description),
        ]);
        let position = i32::try_from(index + 1).unwrap_or(i32::MAX);
        let size = i32::try_from(count).unwrap_or(i32::MAX);
        node.update_relation(&[
            gtk::accessible::Relation::PosInSet(position),
            gtk::accessible::Relation::SetSize(size),
        ]);
        node.set_selected(false);
        node
    }

    pub(crate) fn index(&self) -> usize {
        self.imp().index.get()
    }

    pub(crate) fn set_selected(&self, selected: bool) {
        self.update_state(&[gtk::accessible::State::Selected(Some(selected))]);
    }
}
