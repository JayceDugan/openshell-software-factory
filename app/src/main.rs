use openshell_sdk::{ClientConfig, OpenShellClient};

fn main() {
    let client = OpenShellClient::conect(
        ClientConfig::new("http://127.0.0.1:8080");
    )
    .await?;

    let health = client.health().await?;
    println!("gateway status: {:?}", health.status);
;}
