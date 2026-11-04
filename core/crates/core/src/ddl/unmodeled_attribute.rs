/// A column attribute the catalogue reported and this build does not
/// model, such as MariaDB `WITHOUT SYSTEM VERSIONING`.
///
/// It is kept by name so a redefinition can refuse rather than drop it:
/// restating the column without it would remove it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UnmodeledAttribute {
    pub name: String,
}

impl UnmodeledAttribute {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into() }
    }
}
