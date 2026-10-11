use serde::Deserialize;

use crate::{
    sdam::{description::topology::test::f64_ms_as_duration, monitor::RttInfo},
    test::run_spec_test,
};

#[derive(Debug, Deserialize)]
pub struct TestFile {
    pub avg_rtt_ms: AverageRtt,
    pub new_rtt_ms: f64,
    pub new_avg_rtt: f64,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum AverageRtt {
    F(f64),
    I(i32),
    S(String),
}

async fn run_test(test_file: TestFile) {
    let avg_rtt_ms = match test_file.avg_rtt_ms {
        AverageRtt::F(f) => Some(f),
        AverageRtt::S(ref s) if s == "NULL" => None,
        AverageRtt::I(i) => Some(i as f64),
        AverageRtt::S(ref s) => panic!("invalid average round trip time: {s}"),
    };

    let mut rtt_info = RttInfo {
        average: avg_rtt_ms.map(f64_ms_as_duration),
    };
    rtt_info.add_sample(f64_ms_as_duration(test_file.new_rtt_ms));
    assert_eq!(
        rtt_info.average.unwrap(),
        f64_ms_as_duration(test_file.new_avg_rtt)
    );
}

#[tokio::test]
async fn server_selection_rtt() {
    run_spec_test(&["server-selection", "rtt"], run_test).await;
}
