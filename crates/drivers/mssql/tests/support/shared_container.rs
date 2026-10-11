use tablepro_core::ConnectOptions;
use testcontainers::ContainerAsync;
use testcontainers::core::ExecCommand;
use testcontainers_modules::mssql_server::MssqlServer;

#[path = "mssql_startup.rs"]
mod mssql_startup;

pub(crate) async fn start_mssql() -> (ContainerAsync<MssqlServer>, ConnectOptions) {
    mssql_startup::start_mssql(false).await
}

pub(crate) async fn start_mssql_durable() -> (ContainerAsync<MssqlServer>, ConnectOptions) {
    mssql_startup::start_mssql(true).await
}

pub(crate) async fn assert_tmpfs_data_dir(container: &ContainerAsync<MssqlServer>) {
    let mut result = container.exec(ExecCommand::new(["cat", "/proc/mounts"])).await.unwrap();
    let mounts = String::from_utf8(result.stdout_to_vec().await.unwrap()).unwrap();
    assert!(mounts.lines().any(|line| {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        fields.get(1) == Some(&"/var/opt/mssql") && fields.get(2) == Some(&"tmpfs")
    }));
}
