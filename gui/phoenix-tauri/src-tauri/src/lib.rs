// Phoenix USB Builder - Tauri backend.
//
// VALIDATED CORE PATTERN (2026-09-09): spawn PowerShell via tauri-plugin-shell
// and stream stdout/stderr line-by-line to the Svelte UI through the
// `phx-output` window event. This is how the GUI drives the Phoenix stager
// scripts (answer-file generation, USB build, downloads) without blocking.
//
// ELEVATION: the app runs UNelevated. Only the raw USB-write step elevates,
// via a small helper invoked with the `runas` verb - never by stamping
// requireAdministrator on the whole app (see docs/GUI-PLAN.md).
//
// BOUNDARY: this app runs ONLY on a working Windows machine. It never runs
// in WinPE (no WebView2 there by construction); WinPE goes through headless
// scripts + phoenix-config.json.

use std::path::PathBuf;
use tauri::{AppHandle, Emitter};
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

/// One streamed line from a child PowerShell process.
#[derive(Clone, serde::Serialize)]
struct ScriptLine {
    /// "stdout" | "stderr" | "status"
    stream: String,
    line: String,
}

fn drive_root(drive: &str) -> PathBuf {
    let base = drive.trim_end_matches(['\\', '/']);
    let sep = std::path::MAIN_SEPARATOR;
    PathBuf::from(format!("{base}{sep}"))
}

async fn spawn_and_stream(app: &AppHandle, ps_args: Vec<String>) -> Result<(), String> {
    let (mut rx, _child) = app
        .shell()
        .command("powershell.exe")
        .args(ps_args)
        .spawn()
        .map_err(|e| format!("failed to spawn powershell.exe: {e}"))?;

    let emit = |stream: &str, line: String| {
        let _ = app.emit(
            "phx-output",
            ScriptLine {
                stream: stream.to_string(),
                line,
            },
        );
    };

    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(bytes) => {
                for line in String::from_utf8_lossy(&bytes).lines() {
                    emit("stdout", line.to_string());
                }
            }
            CommandEvent::Stderr(bytes) => {
                for line in String::from_utf8_lossy(&bytes).lines() {
                    emit("stderr", line.to_string());
                }
            }
            CommandEvent::Error(err) => {
                emit("status", format!("process error: {err}"));
            }
            CommandEvent::Terminated(payload) => {
                emit("status", format!("exit code: {:?}", payload.code));
            }
            _ => {}
        }
    }
    Ok(())
}

/// SPIKE (required): spawn a PowerShell *script file* and stream its output
/// lines into the GUI. The Svelte side listens for `phx-output` events.
///
/// Security: the JS-side `Command` API is scope-locked in
/// `capabilities/shell.json` - only `powershell.exe` with an explicit arg
/// allowlist, scripts under the Phoenix tools dir.
#[tauri::command]
async fn stream_powershell_script(
    app: AppHandle,
    script_path: String,
    args: Vec<String>,
) -> Result<(), String> {
    let mut ps_args = vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-File".to_string(),
        script_path,
    ];
    ps_args.extend(args);
    spawn_and_stream(&app, ps_args).await
}

/// SPIKE companion: run an inline PowerShell snippet with streaming.
/// Used by the Diagnostics spike panel; not for production flows.
#[tauri::command]
async fn stream_powershell_inline(app: AppHandle, command: String) -> Result<(), String> {
    spawn_and_stream(
        &app,
        vec![
            "-NoProfile".to_string(),
            "-ExecutionPolicy".to_string(),
            "Bypass".to_string(),
            "-Command".to_string(),
            command,
        ],
    )
    .await
}

#[derive(serde::Serialize)]
struct DriveInfo {
    letter: String,
    label: String,
}

/// Removable drives for the USB picker. Scaffold stub: the real implementation
/// (Get-CimInstance Win32_LogicalDisk via the streaming pattern above, or a
/// Windows crate) lands with the Windows spike run.
#[tauri::command]
fn list_removable_drives() -> Result<Vec<DriveInfo>, String> {
    Err("not implemented yet - wire to Get-CimInstance Win32_LogicalDisk in the Windows spike".into())
}

/// Verify the target is a Ventoy USB (ventoy/ directory present).
/// The builder stages ISOs onto Ventoy; it does not install Ventoy itself.
#[tauri::command]
fn verify_ventoy(drive: String) -> bool {
    drive_root(&drive).join("ventoy").is_dir()
}

/// Write the OS-agnostic phoenix-config.json to the USB.
/// This is THE handoff to the headless boot side.
#[tauri::command]
fn write_phoenix_config(drive: String, config: serde_json::Value) -> Result<String, String> {
    let dir = drive_root(&drive).join("phoenix");
    std::fs::create_dir_all(&dir).map_err(|e| format!("create_dir_all: {e}"))?;
    let path = dir.join("phoenix-config.json");
    let pretty = serde_json::to_string_pretty(&config).map_err(|e| format!("serialize: {e}"))?;
    std::fs::write(&path, pretty).map_err(|e| format!("write: {e}"))?;
    Ok(path.to_string_lossy().into_owned())
}

/// Load data/choco-install/apps.json from the repo checkout.
/// Returns [] when the sibling worker hasn't populated it yet.
#[tauri::command]
fn get_app_catalog(repo_root: String) -> Result<serde_json::Value, String> {
    let path = PathBuf::from(repo_root)
        .join("data")
        .join("choco-install")
        .join("apps.json");
    let raw =
        std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    if raw.trim().is_empty() {
        return Ok(serde_json::Value::Array(vec![]));
    }
    serde_json::from_str(&raw).map_err(|e| format!("parse {}: {e}", path.display()))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            stream_powershell_script,
            stream_powershell_inline,
            list_removable_drives,
            verify_ventoy,
            write_phoenix_config,
            get_app_catalog
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
