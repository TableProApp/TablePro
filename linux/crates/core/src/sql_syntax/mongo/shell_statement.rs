use super::ShellValue;

/// One statement of the shell language the editor takes.
#[derive(Debug, Clone, PartialEq)]
pub enum ShellStatement {
    /// `show dbs`, `show collections` and the like.
    Show(ShowTarget),
    /// `use name`: the editor's database from here on.
    Use(String),
    Call(ShellCall),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShowTarget {
    Databases,
    Collections,
    Users,
    Roles,
}

impl ShowTarget {
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "dbs" | "databases" => Self::Databases,
            "collections" | "tables" => Self::Collections,
            "users" => Self::Users,
            "roles" => Self::Roles,
            _ => return None,
        })
    }
}

/// What a call chain starts from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CallRoot {
    /// `db`, the editor's current database.
    Db,
    /// `rs`, the replica set helpers.
    Rs,
}

/// A chain of method calls, such as
/// `db.getSiblingDB("shop").orders.find({}).sort({at: -1}).limit(5)`.
#[derive(Debug, Clone, PartialEq)]
pub struct ShellCall {
    pub root: CallRoot,
    /// The database `getSiblingDB` named, in place of the current one.
    pub database: Option<String>,
    /// The collection the methods run on, or `None` for the database's
    /// own methods.
    pub collection: Option<String>,
    /// At least one: the operation, then the cursor methods after it.
    pub methods: Vec<ShellMethod>,
}

impl ShellCall {
    /// The method that does the work, the first of the chain.
    pub fn operation(&self) -> Option<&ShellMethod> {
        self.methods.first()
    }

    /// The methods after the operation, which shape its cursor.
    pub fn modifiers(&self) -> &[ShellMethod] {
        self.methods.get(1..).unwrap_or_default()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ShellMethod {
    pub name: String,
    pub args: Vec<ShellValue>,
}

impl ShellMethod {
    pub fn new(name: impl Into<String>, args: Vec<ShellValue>) -> Self {
        Self {
            name: name.into(),
            args,
        }
    }

    pub fn arg(&self, index: usize) -> Option<&ShellValue> {
        self.args.get(index)
    }
}
