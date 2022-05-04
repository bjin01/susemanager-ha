#[allow(unused_imports)]
use tokio_postgres::{NoTls, Error};

#[tokio::main]
async fn main() -> Result<(), Error> {

    let output = if cfg!(target_os = "linux") {
        Command::new("ps")
                .args(&["-aux", "echo hello"])
                .output()
                .expect("failed to execute process")
    }

    let (client, connection) =
        tokio_postgres::connect("host=localhost user=postgres", NoTls).await?;

    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });

    println!("db connected.");

    let rows = client.query("SELECT pid, sent_lsn, state, write_lsn FROM pg_stat_replication", &[])
    .await.unwrap();

    for row in rows
    {
        let a: u32 = row.get("pid");
        let b: Result<&str, _> = row.try_get("sent_lsn");
        let _b = match b {
            Ok(_) => println!("pid: {}, sent_lsn: {}", a, b.unwrap()),
            Err(_error) => println!("pid: {}, sent_lsn: empty", a),
        };
        let c: Result<&str, _> = row.try_get("state");
        let _c = match c {
            Ok(_) => println!("pid: {}, state: {}", a, c.unwrap()),
            Err(_error) => println!("pid: {}, state: empty", a),
        };
    }

    Ok(())
}