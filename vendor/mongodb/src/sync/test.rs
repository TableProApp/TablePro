use std::{
    fmt::Debug,
    io::{Read, Write},
};

use pretty_assertions::assert_eq;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

use crate::{
    bson::{doc, Document},
    error::{Result, TRANSIENT_TRANSACTION_ERROR, UNKNOWN_TRANSACTION_COMMIT_RESULT},
    options::{
        Acknowledgment,
        ClientOptions,
        CollectionOptions,
        DatabaseOptions,
        FindOptions,
        ServerAddress,
        WriteConcern,
    },
    sync::{Client, ClientSession, Collection},
    test::transactions_supported,
    Client as AsyncClient,
};

fn init_db_and_coll(client: &Client, db_name: &str, coll_name: &str) -> Collection<Document> {
    let coll = client.database(db_name).collection(coll_name);
    coll.drop().run().unwrap();
    coll
}

fn init_db_and_typed_coll<T: Send + Sync>(
    client: &Client,
    db_name: &str,
    coll_name: &str,
) -> Collection<T> {
    let coll = client.database(db_name).collection(coll_name);
    coll.drop().run().unwrap();
    coll
}

static CLIENT_OPTIONS: LazyLock<ClientOptions> = LazyLock::new(|| {
    crate::sync::TOKIO_RUNTIME.block_on(async { crate::test::get_client_options().await.clone() })
});

#[test]
fn client_options() {
    let mut options = ClientOptions::parse("mongodb://localhost:27017/")
        .run()
        .unwrap();

    options.original_uri.take();

    assert_eq!(
        options,
        ClientOptions::builder()
            .hosts(vec![ServerAddress::Tcp {
                host: "localhost".into(),
                port: Some(27017)
            }])
            .build()
    );
}

#[test]
#[function_name::named]
fn client() {
    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");

    client
        .database(function_name!())
        .collection(function_name!())
        .insert_one(Document::new())
        .run()
        .expect("insert should succeed");

    let db_names = client
        .list_database_names()
        .run()
        .expect("list_database_names should succeed");
    assert!(db_names.contains(&function_name!().to_string()));
}

#[test]
fn default_database() {
    // here we just test default database name matched, the database interactive logic
    // is tested in `database`.

    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");
    let default_db = client.default_database();
    assert!(default_db.is_none());

    // create client througth options.
    let mut options = CLIENT_OPTIONS.clone();
    options.default_database = Some("abcd".to_string());
    let client = Client::with_options(options).expect("client creation should succeed");
    let default_db = client
        .default_database()
        .expect("should have a default database.");
    assert_eq!(default_db.name(), "abcd");

    // create client directly through uri_str.
    let client = Client::with_uri_str("mongodb://localhost:27017/abcd")
        .expect("client creation should succeed");
    let default_db = client
        .default_database()
        .expect("should have a default database.");
    assert_eq!(default_db.name(), "abcd");
}

#[test]
#[function_name::named]
fn database() {
    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");
    let db = client.database(function_name!());

    let coll = init_db_and_coll(&client, function_name!(), function_name!());

    coll.insert_one(doc! { "x": 1 })
        .run()
        .expect("insert should succeed");

    let coll_names = db
        .list_collection_names()
        .run()
        .expect("list_database_names should succeed");
    assert!(coll_names.contains(&function_name!().to_string()));

    let admin_db = client.database("admin");
    let pipeline = vec![
        doc! { "$currentOp": {} },
        doc! { "$limit": 1 },
        doc! { "$addFields": { "dummy": 1 } },
        doc! { "$project": { "_id": 0, "dummy": 1 } },
    ];
    let cursor = admin_db
        .aggregate(pipeline)
        .run()
        .expect("aggregate should succeed");
    let results: Vec<Document> = cursor
        .collect::<Result<Vec<Document>>>()
        .expect("cursor iteration should succeed");
    assert_eq!(results, vec![doc! { "dummy": 1 }]);

    let wc = WriteConcern {
        w: Some(Acknowledgment::Majority),
        journal: None,
        w_timeout: None,
    };
    let options = DatabaseOptions::builder().write_concern(wc.clone()).build();
    let db = client.database_with_options(function_name!(), options);
    assert!(db.write_concern().is_some());
    assert_eq!(db.write_concern().unwrap(), &wc);
}

#[test]
#[function_name::named]
fn collection() {
    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");
    let coll = init_db_and_coll(&client, function_name!(), function_name!());

    coll.insert_one(doc! { "x": 1 })
        .run()
        .expect("insert should succeed");

    let cursor = coll
        .find(doc! { "x": 1 })
        .projection(doc! { "_id": 0 })
        .run()
        .expect("find should succeed");
    let results = cursor
        .collect::<Result<Vec<Document>>>()
        .expect("cursor iteration should succeed");
    assert_eq!(results, vec![doc! { "x": 1 }]);

    let pipeline = vec![
        doc! { "$match": { "x": 1 } },
        doc! { "$project": { "_id" : 0 } },
    ];
    let cursor = coll
        .aggregate(pipeline)
        .run()
        .expect("aggregate should succeed");
    let results = cursor
        .collect::<Result<Vec<Document>>>()
        .expect("cursor iteration should succeed");
    assert_eq!(results, vec![doc! { "x": 1 }]);

    let wc = WriteConcern {
        w: Acknowledgment::Custom("hello".to_string()).into(),
        journal: None,
        w_timeout: None,
    };
    let db_options = DatabaseOptions::builder().write_concern(wc.clone()).build();
    let coll = client
        .database_with_options(function_name!(), db_options)
        .collection::<Document>(function_name!());
    assert_eq!(coll.write_concern(), Some(&wc));

    let coll_options = CollectionOptions::builder()
        .write_concern(wc.clone())
        .build();
    let coll = client
        .database(function_name!())
        .collection_with_options::<Document>(function_name!(), coll_options);
    assert_eq!(coll.write_concern(), Some(&wc));
}

#[test]
#[function_name::named]
fn typed_collection() {
    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");
    let coll = init_db_and_typed_coll(&client, function_name!(), function_name!());

    #[derive(Serialize, Deserialize, Debug)]
    struct MyType {
        x: i32,
        str: String,
    }
    let my_type = MyType {
        x: 1,
        str: "hello".into(),
    };

    assert!(coll.insert_one(my_type).run().is_ok());
}

#[test]
#[function_name::named]
fn transactions() {
    let should_skip = crate::sync::TOKIO_RUNTIME.block_on(async { transactions_supported().await });
    if should_skip {
        return;
    }

    fn run_transaction_with_retry(
        session: &mut ClientSession,
        f: impl Fn(&mut ClientSession) -> Result<()>,
    ) -> Result<()> {
        loop {
            match f(session) {
                Ok(()) => {
                    return Ok(());
                }
                Err(error) => {
                    if error.contains_label(TRANSIENT_TRANSACTION_ERROR) {
                        continue;
                    } else {
                        session.abort_transaction().run()?;
                        return Err(error);
                    }
                }
            }
        }
    }

    let options = CLIENT_OPTIONS.clone();
    let client = Client::with_options(options).expect("client creation should succeed");
    let mut session = client
        .start_session()
        .run()
        .expect("session creation should succeed");
    let coll = init_db_and_typed_coll(&client, function_name!(), function_name!());

    client
        .database(function_name!())
        .create_collection(function_name!())
        .run()
        .expect("create collection should succeed");

    session
        .start_transaction()
        .run()
        .expect("start transaction should succeed");

    run_transaction_with_retry(&mut session, |s| {
        coll.insert_one(doc! { "x": 1 }).session(s).run()?;
        Ok(())
    })
    .unwrap();

    loop {
        match session.commit_transaction().run() {
            Ok(()) => {
                break;
            }
            Err(error) => {
                if error.contains_label(UNKNOWN_TRANSACTION_COMMIT_RESULT) {
                    continue;
                } else {
                    panic!("error while committing: {error}");
                }
            }
        }
    }

    session
        .start_transaction()
        .run()
        .expect("start transaction should succeed");
    run_transaction_with_retry(&mut session, |s| {
        coll.insert_one(doc! { "x": 1 }).session(s).run()?;
        Ok(())
    })
    .unwrap();
    session
        .abort_transaction()
        .run()
        .expect("abort transaction should succeed");
}

#[test]
#[function_name::named]
fn collection_generic_bounds() {
    #[derive(Deserialize)]
    struct Foo;

    println!("1");
    let options = CLIENT_OPTIONS.clone();
    println!("2");
    let client = Client::with_options(options).expect("client creation should succeed");
    println!("3");

    // ensure this code successfully compiles
    let coll: Collection<Foo> = client
        .database(function_name!())
        .collection(function_name!());
    let _result: Result<Option<Foo>> = coll.find_one(doc! {}).run();

    #[derive(Serialize)]
    struct Bar;

    // ensure this code successfully compiles
    let coll: Collection<Bar> = client
        .database(function_name!())
        .collection(function_name!());
    let _result = coll.insert_one(Bar {});
}

#[test]
fn borrowed_deserialization() {
    let client =
        Client::with_options(CLIENT_OPTIONS.clone()).expect("client creation should succeed");

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct Doc<'a> {
        #[serde(rename = "_id")]
        id: i32,

        #[serde(borrow)]
        foo: &'a str,
    }

    let coll = init_db_and_typed_coll::<Doc>(
        &client,
        "sync_cursor_borrowed_db",
        "sync_cursor_borrowed_coll",
    );

    let docs = vec![
        Doc {
            id: 0,
            foo: "a string",
        },
        Doc {
            id: 1,
            foo: "another string",
        },
        Doc {
            id: 2,
            foo: "more strings",
        },
        Doc {
            id: 3,
            foo: "striiiiiing",
        },
        Doc { id: 4, foo: "s" },
        Doc { id: 5, foo: "1" },
    ];

    coll.insert_many(&docs).run().unwrap();
    let options = FindOptions::builder()
        .batch_size(2)
        .sort(doc! { "_id": 1 })
        .build();

    let mut cursor = coll
        .find(doc! {})
        .with_options(options.clone())
        .run()
        .unwrap();

    let mut i = 0;
    while cursor.advance().unwrap() {
        let de = cursor.deserialize_current().unwrap();
        assert_eq!(de, docs[i]);
        i += 1;
    }

    let mut session = client.start_session().run().unwrap();
    let mut cursor = coll
        .find(doc! {})
        .with_options(options)
        .session(&mut session)
        .run()
        .unwrap();

    let mut i = 0;
    while cursor.advance(&mut session).unwrap() {
        let de = cursor.deserialize_current().unwrap();
        assert_eq!(de, docs[i]);
        i += 1;
    }
}

#[test]
fn mixed_sync_and_async() -> Result<()> {
    const DB_NAME: &str = "mixed_sync_and_async";
    const COLL_NAME: &str = "test";

    let sync_client = Client::with_options(CLIENT_OPTIONS.clone())?;
    let async_client = crate::sync::TOKIO_RUNTIME.block_on(async { AsyncClient::for_test().await });
    let sync_db = sync_client.database(DB_NAME);
    sync_db.drop().run()?;
    sync_db
        .collection::<Document>(COLL_NAME)
        .insert_one(doc! { "a": 1 })
        .run()?;
    let mut found = crate::sync::TOKIO_RUNTIME
        .block_on(async {
            async_client
                .database(DB_NAME)
                .collection::<Document>(COLL_NAME)
                .find_one(doc! {})
                .await
        })?
        .unwrap();
    found.remove("_id");
    assert_eq!(found, doc! { "a": 1 });

    Ok(())
}

#[test]
fn gridfs() {
    let client = Client::with_options(CLIENT_OPTIONS.clone()).unwrap();
    let bucket = client.database("gridfs").gridfs_bucket(None);

    let upload = vec![0u8; 100];
    let mut download = vec![];

    let mut upload_stream = bucket.open_upload_stream("sync gridfs").run().unwrap();
    upload_stream.write_all(&upload[..]).unwrap();
    upload_stream.close().unwrap();

    let mut download_stream = bucket
        .open_download_stream(upload_stream.id().clone())
        .run()
        .unwrap();
    download_stream.read_to_end(&mut download).unwrap();

    assert_eq!(upload, download);
}

#[test]
fn convenient_transactions() {
    let skip = !crate::sync::TOKIO_RUNTIME.block_on(transactions_supported());
    if skip {
        return;
    }

    let client = Client::with_options(CLIENT_OPTIONS.clone()).unwrap();
    let coll = client.database("db").collection("convenient_transaction");
    let mut session = client.start_session().run().unwrap();
    session
        .start_transaction()
        .and_run(|session| coll.insert_one(doc! { "x": 1 }).session(session).run())
        .unwrap();
}
