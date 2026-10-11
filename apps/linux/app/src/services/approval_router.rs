use std::sync::Arc;

use async_trait::async_trait;
use tablepro_policy::{ApprovalOutcome, ApprovalRequest, ApprovalSink, Principal};

pub struct ApprovalRouter {
    human: Arc<dyn ApprovalSink>,
    agent: Arc<dyn ApprovalSink>,
}

impl ApprovalRouter {
    pub fn new(human: Arc<dyn ApprovalSink>, agent: Arc<dyn ApprovalSink>) -> Self {
        Self { human, agent }
    }
}

#[async_trait]
impl ApprovalSink for ApprovalRouter {
    async fn request(&self, request: ApprovalRequest) -> ApprovalOutcome {
        let sink = match &request.principal {
            Principal::Human { .. } => &self.human,
            Principal::Agent { .. } => &self.agent,
        };
        super::approval_wait::measure(sink.request(request)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tablepro_core::{
        ConnectOptions, Connection, DatabaseDriver, DriverError, Environment, OperationControl, TlsConfig,
    };
    use tablepro_policy::{
        ApprovalRequest, AuditError, AuditEvent, AuditSink, AuditState, PolicyConfig, PolicyGuard, Principal,
        StatementClass, StatementFacts,
    };

    struct CountingSink {
        calls: Arc<AtomicUsize>,
        outcome: ApprovalOutcome,
    }

    #[async_trait]
    impl ApprovalSink for CountingSink {
        async fn request(&self, _request: ApprovalRequest) -> ApprovalOutcome {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.outcome
        }
    }

    fn request(principal: Principal) -> ApprovalRequest {
        ApprovalRequest {
            principal,
            environment: Environment::Prod,
            connection_id: uuid::Uuid::new_v4(),
            connection_name: "production".into(),
            sql: "DELETE FROM jobs WHERE id = 1".into(),
            facts: StatementFacts::unparseable("test"),
            rule: "test".into(),
            reason: "test".into(),
            preview: None,
            estimated_rows: None,
            cancellation: None,
        }
    }

    #[tokio::test]
    async fn routes_humans_and_agents_to_distinct_sinks() {
        let human_calls = Arc::new(AtomicUsize::new(0));
        let agent_calls = Arc::new(AtomicUsize::new(0));
        let router = ApprovalRouter::new(
            Arc::new(CountingSink {
                calls: human_calls.clone(),
                outcome: ApprovalOutcome::AllowOnce,
            }),
            Arc::new(CountingSink {
                calls: agent_calls.clone(),
                outcome: ApprovalOutcome::Deny,
            }),
        );

        assert_eq!(
            router.request(request(Principal::human_gui())).await,
            ApprovalOutcome::AllowOnce
        );
        assert_eq!(
            router
                .request(request(Principal::Agent {
                    token: "token".into(),
                    client: None,
                    model: None,
                }))
                .await,
            ApprovalOutcome::Deny
        );
        assert_eq!(human_calls.load(Ordering::SeqCst), 1);
        assert_eq!(agent_calls.load(Ordering::SeqCst), 1);
    }

    struct SequenceSink {
        requests: Mutex<Vec<ApprovalRequest>>,
        outcomes: Mutex<VecDeque<ApprovalOutcome>>,
    }

    #[async_trait]
    impl ApprovalSink for SequenceSink {
        async fn request(&self, request: ApprovalRequest) -> ApprovalOutcome {
            self.requests.lock().unwrap().push(request);
            self.outcomes.lock().unwrap().pop_front().expect("configured outcome")
        }
    }

    struct SuccessfulAuditSink;

    #[async_trait]
    impl AuditSink for SuccessfulAuditSink {
        async fn record(&self, _event: AuditEvent) -> Result<(), AuditError> {
            Ok(())
        }
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn value_contract_mysql_unparseable_procedure_uses_human_approval_before_execution() {
        use testcontainers::ImageExt;
        use testcontainers::runners::AsyncRunner;
        use testcontainers_modules::mysql::Mysql;

        let container = Mysql::default()
            .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
            .with_cmd(["--default-authentication-plugin=mysql_native_password"])
            .start()
            .await
            .expect("start MySQL");
        let options = ConnectOptions {
            host: container.get_host().await.expect("host").to_string(),
            port: container.get_host_port_ipv4(3306).await.expect("port"),
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        };
        let connection: Arc<dyn Connection> = Arc::from(
            drivers_mysql::MysqlDriver
                .connect(options)
                .await
                .expect("connect to MySQL"),
        );
        let connection_id = uuid::Uuid::new_v4();
        let human = Arc::new(SequenceSink {
            requests: Mutex::new(Vec::new()),
            outcomes: Mutex::new(VecDeque::from([ApprovalOutcome::Deny, ApprovalOutcome::AllowOnce])),
        });
        let agent_calls = Arc::new(AtomicUsize::new(0));
        let router = Arc::new(ApprovalRouter::new(
            human.clone(),
            Arc::new(CountingSink {
                calls: agent_calls.clone(),
                outcome: ApprovalOutcome::Deny,
            }),
        ));
        let guard = PolicyGuard::new(
            connection.clone(),
            tablepro_policy::GuardContext {
                connection_id,
                connection_name: "MySQL approval fixture".into(),
                driver_id: "mysql".into(),
                environment: Environment::Prod,
                read_only: false,
                principal: Principal::human_gui(),
                policy: Arc::new(PolicyConfig::default()),
                approval: router,
                audit: Arc::new(SuccessfulAuditSink),
                audit_state: Arc::new(AuditState::new()),
            },
        );
        let mut session = guard.open_session().await.expect("open guarded MySQL session");
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        let sql = "CREATE PROCEDURE bookie_unparseable_approval() SELECT 1";

        assert!(matches!(
            session.query_params_controlled(sql, &[], &control).await,
            Err(DriverError::PolicyDenied(_))
        ));
        assert_eq!(
            mysql_routine_count(connection.as_ref()).await,
            0,
            "denial must stop before MySQL dispatch"
        );

        session
            .query_params_controlled(sql, &[], &control)
            .await
            .expect("the second human approval allows this operation once");
        assert_eq!(
            mysql_routine_count(connection.as_ref()).await,
            1,
            "approval must dispatch to MySQL"
        );

        let requests = human.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        for request in requests.iter() {
            assert_eq!(request.principal, Principal::human_gui());
            assert_eq!(request.connection_id, connection_id);
            assert_eq!(request.connection_name, "MySQL approval fixture");
            assert_eq!(request.sql, sql);
            assert_eq!(request.facts.class, StatementClass::Unparseable);
            assert_eq!(request.rule, "fail_closed_unparseable+human_write_approve");
        }
        assert_eq!(
            agent_calls.load(Ordering::SeqCst),
            0,
            "human approval must not route through agent sink"
        );
    }

    async fn mysql_routine_count(connection: &dyn Connection) -> u64 {
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        let result = connection
            .query_controlled(
                "SELECT COUNT(*) FROM information_schema.routines \
                 WHERE routine_schema = DATABASE() AND routine_name = 'bookie_unparseable_approval'",
                &control,
            )
            .await
            .expect("query MySQL routine catalog");
        match result.rows.first().and_then(|row| row.first()) {
            Some(tablepro_core::Value::Int(count)) => *count as u64,
            value => panic!("unexpected MySQL routine count: {value:?}"),
        }
    }
}
