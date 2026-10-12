use super::form_field::FormField;

/// One thing wrong with the form, pinned to the row that has it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldProblem {
    pub field: FormField,
    pub message: String,
    /// Only empty, as opposed to filled in wrong. An empty row is not
    /// painted as an error before the user has typed anything: the
    /// insensitive Connect button already says the form is incomplete.
    pub missing: bool,
}

/// Every problem the form has, in the order the rows appear.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FormErrors {
    problems: Vec<FieldProblem>,
}

impl FormErrors {
    pub fn push(&mut self, field: FormField, message: String, missing: bool) {
        self.problems.push(FieldProblem {
            field,
            message,
            missing,
        });
    }

    pub fn is_empty(&self) -> bool {
        self.problems.is_empty()
    }

    pub fn problems(&self) -> &[FieldProblem] {
        &self.problems
    }

    pub fn fields(&self) -> impl Iterator<Item = FormField> + '_ {
        self.problems.iter().map(|problem| problem.field)
    }

    pub fn has(&self, field: FormField) -> bool {
        self.fields().any(|candidate| candidate == field)
    }

    /// The sentence for the first problem, which is the one the user
    /// reaches first going down the form.
    pub fn message(&self) -> Option<&str> {
        self.problems.first().map(|problem| problem.message.as_str())
    }

    /// The problem to paint on `field`, if it is one that should show.
    pub fn shown_on(&self, field: FormField) -> Option<&FieldProblem> {
        self.problems
            .iter()
            .find(|problem| problem.field == field && !problem.missing)
    }
}
