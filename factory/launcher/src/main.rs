//! Host-side factory launcher.
//!
//! The LangGraph orchestrator runs inside an OpenShell sandbox and cannot start sandboxes itself.
//! It calls this service over `host.openshell.internal:8787` (granted by the `launcher` provider),
//! and this service starts persona sandboxes through the OpenShell gateway.
//!
//! The launcher is the trust boundary: it holds the gateway's mTLS client identity. Callers name
//! a persona from `openshell/personas/` and a task; image, policy, and providers always come from
//! the persona manifest, never from the request.
//!
//!   GET  /health    gateway health
//!   GET  /personas  personas that can run headless
//!   POST /run       {"persona": "...", "task": "...", "timeout_secs": 900}

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use openshell_core::proto;
use openshell_sdk::{DeleteOptions, EdgeAuthInterceptor, ExecOptions, OpenShellClient};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tonic::transport::{Certificate, ClientTlsConfig, Endpoint, Identity};

const DEFAULT_TIMEOUT_SECS: u64 = 900;
const MAX_TIMEOUT_SECS: u64 = 3600;
const READY_TIMEOUT: Duration = Duration::from_secs(120);

struct AppState {
    client: OpenShellClient,
    /// `openshell/` directory: personas/, harnesses/, policies/.
    fleet_root: PathBuf,
    token: String,
    run_counter: AtomicU64,
}

type Shared = Arc<AppState>;

#[derive(Deserialize)]
struct Persona {
    persona: String,
    harness: String,
    image: String,
    policy: String,
    #[serde(default)]
    providers: Vec<String>,
    launch_cmd: String,
}

#[derive(Deserialize)]
struct Harness {
    #[serde(default)]
    headless_args: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct RunRequest {
    persona: String,
    task: String,
    timeout_secs: Option<u64>,
}

#[derive(Serialize)]
struct RunResponse {
    sandbox: String,
    persona: String,
    exit_code: i32,
    duration_ms: u128,
    stdout: String,
    stderr: String,
}

struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}

fn bad_request(msg: impl Into<String>) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, msg.into())
}

fn internal(msg: impl std::fmt::Display) -> ApiError {
    ApiError(StatusCode::INTERNAL_SERVER_ERROR, msg.to_string())
}

#[tokio::main]
async fn main() {
    let home = PathBuf::from(std::env::var("HOME").expect("HOME is not set"));
    let gateway = std::env::var("OPENSHELL_GATEWAY").unwrap_or_else(|_| "openshell".into());
    let endpoint = std::env::var("FACTORY_GATEWAY_ENDPOINT").unwrap_or_else(|_| "https://localhost:17670".into());
    let bind = std::env::var("FACTORY_LAUNCHER_BIND").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let fleet_root = std::env::var("FACTORY_FLEET_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../openshell")
    });
    let fleet_root = fleet_root.canonicalize().expect("fleet root (openshell/) not found");
    let token_path = home.join(".config/factory/launcher.token");
    let token = std::fs::read_to_string(&token_path)
        .unwrap_or_else(|e| panic!("read {}: {e}", token_path.display()))
        .trim()
        .to_string();
    assert!(token.len() >= 32, "launcher token is too short");

    let mtls = home.join(".config/openshell/gateways").join(&gateway).join("mtls");
    let client = connect(&endpoint, &mtls).await;
    let health = client.health().await.expect("gateway health check failed");
    println!("gateway {endpoint}: {:?} {}", health.status, health.version);

    let state = Arc::new(AppState { client, fleet_root, token, run_counter: AtomicU64::new(0) });
    let app = Router::new()
        .route("/health", get(health_handler))
        .route("/personas", get(personas_handler))
        .route("/run", post(run_handler))
        .layer(middleware::from_fn_with_state(state.clone(), require_token))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&bind).await.expect("bind launcher address");
    println!("launcher listening on http://{bind}");
    axum::serve(listener, app).await.expect("server error");
}

/// The SDK's `connect` has no client-certificate support, and the local gateway is mTLS, so the
/// channel is built here the same way `openshell-cli/src/tls.rs` does it.
async fn connect(endpoint: &str, mtls: &Path) -> OpenShellClient {
    let read = |f: &str| std::fs::read(mtls.join(f)).unwrap_or_else(|e| panic!("read {}/{f}: {e}", mtls.display()));
    let host = endpoint
        .split("://")
        .nth(1)
        .and_then(|rest| rest.split([':', '/']).next())
        .expect("gateway endpoint has no host");
    let tls = ClientTlsConfig::new()
        .ca_certificate(Certificate::from_pem(read("ca.crt")))
        .identity(Identity::from_pem(read("tls.crt"), read("tls.key")))
        .domain_name(host);
    let channel = Endpoint::from_shared(endpoint.to_string())
        .expect("invalid gateway endpoint")
        .connect_timeout(Duration::from_secs(10))
        .tls_config(tls)
        .expect("invalid TLS config")
        .connect()
        .await
        .expect("connect to gateway");
    let interceptor = EdgeAuthInterceptor::new(None, None).expect("no-op interceptor");
    OpenShellClient::from_parts(channel, interceptor)
}

async fn require_token(State(state): State<Shared>, req: Request, next: Next) -> Response {
    let presented = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if !constant_time_eq(presented.as_bytes(), state.token.as_bytes()) {
        return ApiError(StatusCode::UNAUTHORIZED, "missing or invalid bearer token".into()).into_response();
    }
    next.run(req).await
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn health_handler(State(state): State<Shared>) -> Result<Json<serde_json::Value>, ApiError> {
    let health = state.client.health().await.map_err(internal)?;
    Ok(Json(json!({ "launcher": "ok", "gateway": format!("{:?}", health.status), "version": health.version })))
}

async fn personas_handler(State(state): State<Shared>) -> Result<Json<serde_json::Value>, ApiError> {
    let mut names: Vec<String> = std::fs::read_dir(state.fleet_root.join("personas"))
        .map_err(internal)?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|name| load_runnable(&state.fleet_root, name).is_ok())
        .collect();
    names.sort();
    Ok(Json(json!({ "personas": names })))
}

/// Resolve a persona name to its manifest and harness headless args, refusing anything that is
/// not a plain directory name under personas/ or whose harness has no verified headless mode.
fn load_runnable(root: &Path, name: &str) -> Result<(Persona, Vec<String>), ApiError> {
    let valid = !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !valid {
        return Err(bad_request(format!("invalid persona name {name:?}")));
    }
    let manifest = root.join("personas").join(name).join("persona.json");
    let persona: Persona = read_json(&manifest).map_err(|_| bad_request(format!("unknown persona {name:?}")))?;
    let harness: Harness = read_json(&root.join("harnesses").join(format!("{}.json", persona.harness)))
        .map_err(|e| internal(format!("harness {}: {e}", persona.harness)))?;
    let args = harness
        .headless_args
        .ok_or_else(|| bad_request(format!("harness {} has no verified headless_args", persona.harness)))?;
    Ok((persona, args))
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

async fn run_handler(State(state): State<Shared>, Json(req): Json<RunRequest>) -> Result<Json<RunResponse>, ApiError> {
    let (persona, headless_args) = load_runnable(&state.fleet_root, &req.persona)?;
    if req.task.trim().is_empty() {
        return Err(bad_request("task is empty"));
    }
    let timeout = Duration::from_secs(req.timeout_secs.unwrap_or(DEFAULT_TIMEOUT_SECS).min(MAX_TIMEOUT_SECS));
    let name = sandbox_name(&state.run_counter);
    let started = Instant::now();
    println!("run {name}: creating");

    // axum drops this handler's future when the caller disconnects, which would skip the delete
    // below and leak the sandbox. A spawned task runs to completion regardless.
    let job = {
        let (state, name) = (state.clone(), name.clone());
        tokio::spawn(async move {
            create_sandbox(&state, &persona, &name).await?;
            // From here on the sandbox exists, so every path must delete it.
            let outcome = run_in_sandbox(&state, &persona, &headless_args, &name, &req.task, timeout).await;
            if let Err(e) = state.client.delete_sandbox(&name, DeleteOptions::default()).await {
                eprintln!("run {name}: delete failed, remove it by hand: {e}");
            }
            outcome.map(|result| (persona, result))
        })
    };
    let (persona, result) = job.await.map_err(internal)??;
    println!("run {name}: exit {} in {:?}", result.exit_code, started.elapsed());
    Ok(Json(RunResponse {
        sandbox: name,
        persona: persona.persona,
        exit_code: result.exit_code,
        duration_ms: started.elapsed().as_millis(),
        stdout: String::from_utf8_lossy(&result.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&result.stderr).into_owned(),
    }))
}

/// The gateway caps sandbox names at 19 characters, so the persona goes in a label instead.
fn sandbox_name(counter: &AtomicU64) -> String {
    let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    format!("fx-{}-{}", base36(millis), counter.fetch_add(1, Ordering::Relaxed) % 1000)
}

fn base36(mut n: u128) -> String {
    let mut out = Vec::new();
    loop {
        out.push(b"0123456789abcdefghijklmnopqrstuvwxyz"[(n % 36) as usize]);
        n /= 36;
        if n == 0 {
            break;
        }
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

/// Create the sandbox through the raw RPC: the curated `SandboxSpec` has no policy field.
/// The main process just idles; the agent runs via exec so its output comes back buffered.
async fn create_sandbox(state: &AppState, persona: &Persona, name: &str) -> Result<(), ApiError> {
    let policy_path = state.fleet_root.join(&persona.policy);
    let policy = openshell_policy::parse_sandbox_policy_file(&policy_path)
        .map_err(|e| internal(format!("policy {}: {e}", policy_path.display())))?;
    let request = proto::CreateSandboxRequest {
        name: name.to_string(),
        labels: HashMap::from([
            ("factory".to_string(), "launcher".to_string()),
            ("factory-persona".to_string(), persona.persona.clone()),
        ]),
        annotations: HashMap::from([(
            "openshell.nvidia.com/retention".to_string(),
            "ephemeral".to_string(),
        )]),
        workspace_scope: Some(proto::workspace_selector("default")),
        spec: Some(proto::SandboxSpec {
            policy: Some(policy),
            providers: persona.providers.clone(),
            template: Some(proto::SandboxTemplate { image: persona.image.clone(), ..Default::default() }),
            command: vec!["sleep".into(), "infinity".into()],
            restart_policy: proto::SandboxRestartPolicy::Never as i32,
            ..Default::default()
        }),
        ..Default::default()
    };
    state.client.raw_grpc().create_sandbox(request).await.map_err(internal)?;
    Ok(())
}

async fn run_in_sandbox(
    state: &AppState,
    persona: &Persona,
    headless_args: &[String],
    name: &str,
    task: &str,
    timeout: Duration,
) -> Result<openshell_sdk::ExecResult, ApiError> {
    state.client.wait_ready(name, READY_TIMEOUT).await.map_err(internal)?;
    // `cd /sandbox/work`: OpenShell ignores the image WORKDIR and omp refuses to work in $HOME.
    // `</dev/null`: pi reads non-TTY stdin to EOF and hangs otherwise.
    let mut cmd: Vec<String> = vec![
        "sh".into(),
        "-c".into(),
        r#"mkdir -p /sandbox/work 2>/dev/null; cd /sandbox/work || exit 1; exec "$@" </dev/null"#.into(),
        "sh".into(),
    ];
    cmd.extend(persona.launch_cmd.split_whitespace().map(String::from));
    cmd.extend(headless_args.iter().cloned());
    cmd.push(task.to_string());
    let opts = ExecOptions { timeout: Some(timeout), ..Default::default() };
    state.client.exec(name, &cmd, opts).await.map_err(internal)
}
