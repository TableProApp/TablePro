mod connection_lookup;
mod describe;
mod export;
mod listing;
mod query;
mod sql_source;
mod status;

use crate::command_error::CommandError;
use crate::command_line::Command;
use crate::console::Console;
use crate::exit::Exit;
use crate::host::Host;

// One request at a time, so a runtime on this thread is all a run needs.
pub(crate) fn execute(
    command: Command,
    host: &(impl Host + Clone + Send + Sync + 'static),
    console: &mut Console<'_>,
) -> Exit {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return console.fail(&CommandError::Runtime(error.to_string())),
    };
    match runtime.block_on(dispatch(command, host, console)) {
        Ok(exit) => exit,
        Err(error) => console.fail(&error),
    }
}

async fn dispatch(
    command: Command,
    host: &(impl Host + Clone + Send + Sync + 'static),
    console: &mut Console<'_>,
) -> Result<Exit, CommandError> {
    let done = match command {
        Command::Status(arguments) => return status::run(&arguments, host, console).await,
        Command::Query(arguments) => query::run(&arguments, host, console).await,
        Command::Connections(arguments) => listing::connections(&arguments, host, console).await,
        Command::Databases(arguments) => listing::databases(&arguments, host, console).await,
        Command::Schemas(arguments) => listing::schemas(&arguments, host, console).await,
        Command::Tables(arguments) => listing::tables(&arguments, host, console).await,
        Command::Describe(arguments) => describe::run(&arguments, host, console).await,
        Command::Export(arguments) => export::run(&arguments, host, console).await,
        Command::Open(_) | Command::Completion(_) => Err(CommandError::OpensInApp),
    };
    done.map(|()| Exit::Success)
}
