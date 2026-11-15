//! Phoenix desktop backend.
//!
//! The frontend never builds PowerShell. Everything system-facing goes through
//! `scripts/engine/phoenix.ps1` (see docs/ARCHITECTURE.md), spawned here with a fixed
//! argument shape and a command allowlist. Engine output is NDJSON; each line is
//! forwarded to the UI as an `engine-event`, and every run ends with `engine-exit`.

use base64::Engine as _;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_opener::OpenerExt;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Must match the command table in scripts/engine/phoenix.ps1.
const ALLOWED_COMMANDS: &[&str] = &[
    "version", "profile", "packs", "plan", "apply", "undo", "snapshots", "scan", "state", "mark",
    "runbook", "drives", "unattend", "loadout", "fetch", "usb-build", "usb-verify", "choco-search",
    "launch", "unattend-schema", "unattend-defaults",
];

/// Commands whose args carry `configPath`. The app always passes it explicitly:
/// an elevated run may execute as a different user (UAC over-the-shoulder with
/// the admin account) whose %APPDATA% is not ours.
const CONFIG_COMMANDS: &[&str] = &["profile", "plan", "apply", "unattend", "usb-build"];

/// Exit code the elevation launcher uses when the UAC prompt is declined.
const UAC_CANCELLED: i32 = 1223;

#[derive(Default)]
struct Runs {
    next: AtomicU64,
    children: Mutex<HashMap<u64, Arc<Mutex<Child>>>>,
    cancelled: Mutex<HashSet<u64>>,
}

type RunsState = Arc<Runs>;

// ---------------------------------------------------------------- paths

fn env_dir(var: &str) -> Result<PathBuf, String> {
    std::env::var_os(var)
        .map(PathBuf::from)
        .ok_or_else(|| format!("%{var}% is not set"))
}

/// The engine script under a kit root.
fn engine_in(kit: &Path) -> PathBuf {
    kit.join("scripts").join("engine").join("phoenix.ps1")
}

fn has_engine(dir: &Path) -> bool {
    engine_in(dir).is_file()
}

/// Kit root = the folder holding scripts\engine\, config\ and app\ (same layout
/// in the repo, on the USB and installed).
/// 1. %PHOENIX_KIT_ROOT%  2. walk up from the exe (repo in dev, <USB>\phoenix on the stick)
/// 3. C:\ProgramData\Phoenix\kit (installed by FirstLogon).
fn kit_root() -> Result<PathBuf, String> {
    if let Some(p) = std::env::var_os("PHOENIX_KIT_ROOT") {
        let p = PathBuf::from(p);
        if has_engine(&p) {
            return Ok(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..8 {
            match dir {
                Some(d) => {
                    if has_engine(&d) {
                        return Ok(d);
                    }
                    dir = d.parent().map(Path::to_path_buf);
                }
                None => break,
            }
        }
    }
    if let Ok(pd) = env_dir("ProgramData") {
        let p = pd.join("Phoenix").join("kit");
        if has_engine(&p) {
            return Ok(p);
        }
    }
    Err("Phoenix engine not found. Set PHOENIX_KIT_ROOT or run Phoenix.exe from the kit folder.".into())
}

fn engine_script() -> Result<PathBuf, String> {
    Ok(engine_in(&kit_root()?))
}

fn tmp_dir() -> Result<PathBuf, String> {
    let d = env_dir("LOCALAPPDATA")?.join("Phoenix").join("tmp");
    fs::create_dir_all(&d).map_err(|e| format!("create {}: {e}", d.display()))?;
    Ok(d)
}

fn user_config_path() -> Result<PathBuf, String> {
    Ok(env_dir("APPDATA")?.join("Phoenix").join("phoenix.config.json"))
}

/// The config file the engine should read: the user's saved one, else the kit's
/// (USB/installed), else the repo example.
fn effective_config_path() -> Option<PathBuf> {
    if let Ok(p) = user_config_path() {
        if p.is_file() {
            return Some(p);
        }
    }
    let kit = kit_root().ok()?;
    [kit.join("phoenix.config.json"), kit.join("config").join("phoenix.example.json")]
        .into_iter()
        .find(|p| p.is_file())
}

fn unique_name(prefix: &str, ext: &str) -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{prefix}-{}-{nanos}.{ext}", std::process::id())
}

fn valid_pack_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn read_json_file(p: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(p).map_err(|e| format!("read {}: {e}", p.display()))?;
    let text = text.trim_start_matches('\u{feff}');
    serde_json::from_str(text).map_err(|e| format!("parse {}: {e}", p.display()))
}

fn write_json_file(p: &Path, v: &Value) -> Result<(), String> {
    if let Some(dir) = p.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    }
    let text = serde_json::to_string_pretty(v).map_err(|e| e.to_string())?;
    fs::write(p, text + "\n").map_err(|e| format!("write {}: {e}", p.display()))
}

// ---------------------------------------------------------------- engine runner

fn emit_event(app: &AppHandle, run_id: u64, event: &Value) {
    let _ = app.emit("engine-event", json!({ "runId": run_id, "event": event }));
}

fn now_ts() -> String {
    // Engine events carry real ISO timestamps; synthetic ones only need ordering.
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    format!("@{secs}")
}

fn log_event(level: &str, msg: &str) -> Value {
    json!({ "t": "log", "ts": now_ts(), "level": level, "msg": msg })
}

/// Parses one stdout/log line. Non-JSON output (stray Write-Host, PS errors) is
/// wrapped as a log event so nothing is lost.
fn handle_line(app: &AppHandle, run_id: u64, line: &str, result: &mut Option<Value>) {
    let line = line.trim().trim_start_matches('\u{feff}');
    if line.is_empty() {
        return;
    }
    match serde_json::from_str::<Value>(line) {
        Ok(v) if v.get("t").is_some() => {
            if v.get("t").and_then(Value::as_str) == Some("result") {
                *result = Some(v.clone());
            }
            emit_event(app, run_id, &v);
        }
        _ => emit_event(app, run_id, &log_event("info", line)),
    }
}

fn prepare_args(command: &str, args: Value) -> Result<PathBuf, String> {
    if !ALLOWED_COMMANDS.contains(&command) {
        return Err(format!("Command '{command}' is not allowed"));
    }
    let mut obj = match args {
        Value::Object(m) => m,
        Value::Null => Map::new(),
        _ => return Err("Engine args must be a JSON object".into()),
    };
    if CONFIG_COMMANDS.contains(&command) && !obj.contains_key("configPath") {
        if let Some(p) = effective_config_path() {
            obj.insert("configPath".into(), Value::String(p.to_string_lossy().into_owned()));
        }
    }
    let path = tmp_dir()?.join(unique_name("args", "json"));
    write_json_file(&path, &Value::Object(obj))?;
    Ok(path)
}

fn finish(app: &AppHandle, run_id: u64, code: i32, result: Option<Value>) -> Value {
    let result = result.unwrap_or_else(|| {
        let msg = match code {
            UAC_CANCELLED => "The administrator prompt was cancelled.".to_string(),
            -1 => "Cancelled.".to_string(),
            c => format!("Engine exited with code {c} without a result."),
        };
        let v = json!({ "t": "result", "ts": now_ts(), "ok": false,
                        "data": { "error": msg, "needsAdmin": false, "exitCode": code } });
        emit_event(app, run_id, &v);
        v
    });
    let _ = app.emit("engine-exit", json!({ "runId": run_id, "code": code }));
    result
}

fn base_command() -> Command {
    let mut c = Command::new("powershell.exe");
    #[cfg(windows)]
    c.creation_flags(CREATE_NO_WINDOW);
    c.stdin(Stdio::null());
    c
}

/// Runs the engine un-elevated, streaming stdout. Returns the result event.
fn run_plain(app: &AppHandle, runs: &RunsState, run_id: u64, command: &str, args_path: &Path) -> Value {
    let engine = match engine_script() {
        Ok(e) => e,
        Err(e) => {
            emit_event(app, run_id, &log_event("error", &e));
            return finish(app, run_id, 1, None);
        }
    };
    let mut c = base_command();
    c.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&engine)
        .arg(command)
        .arg("-ArgsPath")
        .arg(args_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => {
            emit_event(app, run_id, &log_event("error", &format!("Could not start powershell.exe: {e}")));
            return finish(app, run_id, 1, None);
        }
    };
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let child = Arc::new(Mutex::new(child));
    runs.children.lock().unwrap().insert(run_id, child.clone());

    let err_thread = stderr.map(|s| {
        let app = app.clone();
        thread::spawn(move || {
            let mut r = BufReader::new(s);
            let mut buf = Vec::new();
            while r.read_until(b'\n', &mut buf).map(|n| n > 0).unwrap_or(false) {
                let line = String::from_utf8_lossy(&buf).trim().to_string();
                if !line.is_empty() {
                    emit_event(&app, run_id, &log_event("error", &line));
                }
                buf.clear();
            }
        })
    });

    let mut result = None;
    if let Some(s) = stdout {
        let mut r = BufReader::new(s);
        let mut buf = Vec::new();
        while r.read_until(b'\n', &mut buf).map(|n| n > 0).unwrap_or(false) {
            handle_line(app, run_id, &String::from_utf8_lossy(&buf), &mut result);
            buf.clear();
        }
    }
    if let Some(t) = err_thread {
        let _ = t.join();
    }
    let code = child.lock().unwrap().wait().ok().and_then(|s| s.code()).unwrap_or(1);
    runs.children.lock().unwrap().remove(&run_id);
    let code = if runs.cancelled.lock().unwrap().remove(&run_id) { -1 } else { code };
    finish(app, run_id, code, result)
}

/// Elevation launcher: an un-elevated, hidden PowerShell that starts the engine
/// with -Verb RunAs and waits. The elevated engine's stdout is invisible to us,
/// so it writes events to -LogPath, which we tail.
const ELEVATE_LAUNCHER: &str = r#"
$ErrorActionPreference = 'Stop'
$a = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1} -ArgsPath "{2}" -LogPath "{3}"' -f $env:PHX_ENGINE, $env:PHX_CMD, $env:PHX_ARGS, $env:PHX_LOG
try {
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList $a
} catch { exit 1223 }
exit $p.ExitCode
"#;

fn encoded(script: &str) -> String {
    let utf16: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    base64::engine::general_purpose::STANDARD.encode(utf16)
}

/// Reads whatever was appended to the log since `offset`, emitting whole lines.
fn drain_log(app: &AppHandle, run_id: u64, path: &Path, offset: &mut u64, partial: &mut String, result: &mut Option<Value>) {
    let Ok(mut f) = fs::File::open(path) else { return };
    if f.seek(SeekFrom::Start(*offset)).is_err() {
        return;
    }
    let mut bytes = Vec::new();
    if let Ok(n) = f.read_to_end(&mut bytes) {
        *offset += n as u64;
    }
    if bytes.is_empty() {
        return;
    }
    partial.push_str(&String::from_utf8_lossy(&bytes));
    while let Some(i) = partial.find('\n') {
        let line: String = partial.drain(..=i).collect();
        handle_line(app, run_id, &line, result);
    }
}

fn run_elevated(app: &AppHandle, runs: &RunsState, run_id: u64, command: &str, args_path: &Path) -> Value {
    let setup = (|| -> Result<(PathBuf, PathBuf), String> {
        let engine = engine_script()?;
        let log = tmp_dir()?.join(unique_name("elevated", "ndjson"));
        fs::write(&log, b"").map_err(|e| format!("create {}: {e}", log.display()))?;
        Ok((engine, log))
    })();
    let (engine, log) = match setup {
        Ok(v) => v,
        Err(e) => {
            emit_event(app, run_id, &log_event("error", &e));
            return finish(app, run_id, 1, None);
        }
    };
    emit_event(app, run_id, &log_event("info", "Waiting for the administrator (UAC) prompt..."));
    let mut c = base_command();
    c.args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &encoded(ELEVATE_LAUNCHER)])
        .env("PHX_ENGINE", &engine)
        .env("PHX_CMD", command)
        .env("PHX_ARGS", args_path)
        .env("PHX_LOG", &log)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let child = match c.spawn() {
        Ok(ch) => Arc::new(Mutex::new(ch)),
        Err(e) => {
            emit_event(app, run_id, &log_event("error", &format!("Could not start powershell.exe: {e}")));
            return finish(app, run_id, 1, None);
        }
    };
    runs.children.lock().unwrap().insert(run_id, child.clone());

    let (mut offset, mut partial, mut result) = (0u64, String::new(), None);
    let code = loop {
        drain_log(app, run_id, &log, &mut offset, &mut partial, &mut result);
        if runs.cancelled.lock().unwrap().contains(&run_id) {
            let _ = child.lock().unwrap().kill();
            emit_event(app, run_id, &log_event("warn",
                "Stopped watching. The elevated engine may still be finishing; check the log folder."));
            break -1;
        }
        match child.lock().unwrap().try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(1),
            Ok(None) => {}
            Err(_) => break 1,
        }
        thread::sleep(Duration::from_millis(150));
    };
    drain_log(app, run_id, &log, &mut offset, &mut partial, &mut result);
    if !partial.trim().is_empty() {
        let rest = std::mem::take(&mut partial);
        handle_line(app, run_id, &rest, &mut result);
    }
    runs.children.lock().unwrap().remove(&run_id);
    runs.cancelled.lock().unwrap().remove(&run_id);
    finish(app, run_id, code, result)
}

fn run_engine(app: AppHandle, runs: RunsState, run_id: u64, command: String, args: Value, elevated: bool) -> Value {
    // Lets the UI label every run (including blocking engine_call runs) before events arrive.
    let _ = app.emit("engine-start", json!({ "runId": run_id, "command": command, "elevated": elevated }));
    let args_path = match prepare_args(&command, args) {
        Ok(p) => p,
        Err(e) => {
            emit_event(&app, run_id, &log_event("error", &e));
            return finish(&app, run_id, 1, None);
        }
    };
    let r = if elevated {
        run_elevated(&app, &runs, run_id, &command, &args_path)
    } else {
        run_plain(&app, &runs, run_id, &command, &args_path)
    };
    // The engine may already have consumed it; secrets files are deleted by the engine.
    let _ = fs::remove_file(&args_path);
    r
}

fn new_run(runs: &RunsState) -> u64 {
    runs.next.fetch_add(1, Ordering::SeqCst) + 1
}

// ---------------------------------------------------------------- commands

/// Starts an engine run in the background; returns its id at once. Events follow.
#[tauri::command]
fn engine_run(app: AppHandle, runs: State<'_, RunsState>, command: String, args: Option<Value>) -> Result<u64, String> {
    if !ALLOWED_COMMANDS.contains(&command.as_str()) {
        return Err(format!("Command '{command}' is not allowed"));
    }
    let runs = runs.inner().clone();
    let id = new_run(&runs);
    thread::spawn(move || {
        run_engine(app, runs, id, command, args.unwrap_or(Value::Null), false);
    });
    Ok(id)
}

/// Same as engine_run, but elevated through UAC.
#[tauri::command]
fn engine_run_elevated(app: AppHandle, runs: State<'_, RunsState>, command: String, args: Option<Value>) -> Result<u64, String> {
    if !ALLOWED_COMMANDS.contains(&command.as_str()) {
        return Err(format!("Command '{command}' is not allowed"));
    }
    let runs = runs.inner().clone();
    let id = new_run(&runs);
    thread::spawn(move || {
        run_engine(app, runs, id, command, args.unwrap_or(Value::Null), true);
    });
    Ok(id)
}

/// Runs to completion and returns the result event ({t, ok, data}). Events are
/// still emitted, so the log drawer sees quick calls too.
#[tauri::command]
async fn engine_call(app: AppHandle, runs: State<'_, RunsState>, command: String, args: Option<Value>, elevated: Option<bool>) -> Result<Value, String> {
    if !ALLOWED_COMMANDS.contains(&command.as_str()) {
        return Err(format!("Command '{command}' is not allowed"));
    }
    let runs = runs.inner().clone();
    let id = new_run(&runs);
    let elevated = elevated.unwrap_or(false);
    tauri::async_runtime::spawn_blocking(move || run_engine(app, runs, id, command, args.unwrap_or(Value::Null), elevated))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn engine_cancel(runs: State<'_, RunsState>, run_id: u64) -> bool {
    let child = runs.children.lock().unwrap().get(&run_id).cloned();
    match child {
        Some(c) => {
            runs.cancelled.lock().unwrap().insert(run_id);
            let _ = c.lock().unwrap().kill();
            true
        }
        None => false,
    }
}

#[tauri::command]
fn app_context() -> Value {
    let kit = kit_root();
    let kit_path = kit.as_ref().ok().cloned();
    json!({
        "kitRoot": kit_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
        "engineFound": kit.is_ok(),
        "engineError": kit.err(),
        "isUsbKit": kit_path.as_ref().map(|p| p.join("phoenix.id").is_file()).unwrap_or(false),
        "isInstalledKit": kit_path.as_ref().map(|p| p.ends_with("Phoenix\\kit") || p.ends_with("Phoenix/kit")).unwrap_or(false),
        "configPath": effective_config_path().map(|p| p.to_string_lossy().into_owned()),
        "userConfigPath": user_config_path().ok().map(|p| p.to_string_lossy().into_owned()),
        "exePath": std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()),
    })
}

#[tauri::command]
fn config_load() -> Result<Value, String> {
    let user = user_config_path()?;
    let path = effective_config_path().ok_or("No Phoenix config found (no saved config and no example in the kit).")?;
    let mut cfg = read_json_file(&path)?;
    if let Value::Object(m) = &mut cfg {
        m.remove("_path");
    }
    Ok(json!({ "path": path.to_string_lossy(), "isUserConfig": path == user, "config": cfg }))
}

#[tauri::command]
fn config_save(config: Value) -> Result<String, String> {
    let mut config = config;
    match &mut config {
        Value::Object(m) => {
            m.remove("_path");
        }
        _ => return Err("Config must be a JSON object".into()),
    }
    let p = user_config_path()?;
    write_json_file(&p, &config)?;
    Ok(p.to_string_lossy().into_owned())
}

fn pack_path(id: &str) -> Result<PathBuf, String> {
    if !valid_pack_id(id) {
        return Err(format!("Invalid pack id '{id}' (use a-z, 0-9 and '-')"));
    }
    Ok(kit_root()?.join("config").join("packs").join(format!("{id}.json")))
}

#[tauri::command]
fn pack_read(id: String) -> Result<Value, String> {
    read_json_file(&pack_path(&id)?)
}

#[tauri::command]
fn pack_save(id: String, value: Value) -> Result<String, String> {
    if value.get("id").and_then(Value::as_str) != Some(id.as_str()) {
        return Err("Pack 'id' field must match the file name".into());
    }
    let p = pack_path(&id)?;
    write_json_file(&p, &value)?;
    Ok(p.to_string_lossy().into_owned())
}

/// Copies a pack file into the kit's packs folder. Returns its id.
#[tauri::command]
fn pack_import(path: String, overwrite: Option<bool>) -> Result<String, String> {
    let v = read_json_file(Path::new(&path))?;
    let id = v.get("id").and_then(Value::as_str).ok_or("Pack file has no 'id'")?.to_string();
    if v.get("steps").map(|s| !s.is_array()).unwrap_or(true) {
        return Err("Pack file has no 'steps' array".into());
    }
    let dest = pack_path(&id)?;
    if dest.exists() && !overwrite.unwrap_or(false) {
        return Err(format!("A pack named '{id}' already exists"));
    }
    write_json_file(&dest, &v)?;
    Ok(id)
}

#[tauri::command]
fn pack_export(id: String, path: String) -> Result<(), String> {
    let v = read_json_file(&pack_path(&id)?)?;
    write_json_file(Path::new(&path), &v)
}

/// Local app catalog for the picker. First match wins.
#[tauri::command]
fn catalog_load() -> Result<Value, String> {
    let kit = kit_root()?;
    for rel in ["config/catalog/apps.json"] {
        let p = kit.join(rel);
        if p.is_file() {
            let v = read_json_file(&p)?;
            let items = match v {
                Value::Array(_) => v,
                Value::Object(ref m) => m.get("apps").cloned().unwrap_or(Value::Array(vec![])),
                _ => Value::Array(vec![]),
            };
            return Ok(json!({ "source": rel, "apps": items }));
        }
    }
    Ok(json!({ "source": null, "apps": [] }))
}

/// Writes a short-lived secrets file for the engine (which deletes it after
/// reading). Lives under %LOCALAPPDATA%\Phoenix\tmp, private to this user.
#[tauri::command]
fn secrets_write(value: Value) -> Result<String, String> {
    if !value.is_object() {
        return Err("Secrets must be a JSON object".into());
    }
    let p = tmp_dir()?.join(unique_name("secrets", "json"));
    fs::write(&p, serde_json::to_vec(&value).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    #[cfg(windows)]
    {
        // Best effort: strip inherited ACEs, grant only the current user.
        if let Ok(user) = std::env::var("USERNAME") {
            let _ = base_command_icacls(&p, &user);
        }
    }
    Ok(p.to_string_lossy().into_owned())
}

#[cfg(windows)]
fn base_command_icacls(p: &Path, user: &str) -> std::io::Result<std::process::ExitStatus> {
    let mut c = Command::new("icacls.exe");
    c.creation_flags(CREATE_NO_WINDOW);
    c.arg(p).args(["/inheritance:r", "/grant:r"]).arg(format!("{user}:F"))
        .stdout(Stdio::null()).stderr(Stdio::null()).status()
}

/// Only files directly inside %LOCALAPPDATA%\Phoenix	mp may be read/deleted by path.
fn in_tmp(path: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(path);
    let tmp = tmp_dir()?;
    let parent = p.parent().and_then(|d| fs::canonicalize(d).ok());
    if parent.is_none() || parent != fs::canonicalize(&tmp).ok() {
        return Err("Path is outside the Phoenix temp folder".into());
    }
    Ok(p)
}

#[tauri::command]
fn secrets_discard(path: String) -> Result<(), String> {
    let _ = fs::remove_file(in_tmp(&path)?);
    Ok(())
}

/// A fresh path in the Phoenix temp folder (file not created).
#[tauri::command]
fn tmp_file(prefix: String, ext: String) -> Result<String, String> {
    let ok = |s: &str| !s.is_empty() && s.len() <= 24 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !ok(&prefix) || !ok(&ext) {
        return Err("Invalid temp file name".into());
    }
    Ok(tmp_dir()?.join(unique_name(&prefix, &ext)).to_string_lossy().into_owned())
}

#[tauri::command]
fn tmp_read_text(path: String) -> Result<String, String> {
    let p = in_tmp(&path)?;
    fs::read_to_string(&p).map_err(|e| format!("read {}: {e}", p.display()))
}

/// Copies a generated temp file to where the user chose (save dialog), then deletes the temp copy.
#[tauri::command]
fn tmp_save_as(path: String, dest: String, keep: Option<bool>) -> Result<(), String> {
    let p = in_tmp(&path)?;
    fs::copy(&p, &dest).map_err(|e| format!("save {dest}: {e}"))?;
    if !keep.unwrap_or(false) {
        let _ = fs::remove_file(&p);
    }
    Ok(())
}

#[tauri::command]
fn tmp_discard(path: String) -> Result<(), String> {
    let _ = fs::remove_file(in_tmp(&path)?);
    Ok(())
}

/// Reads a user-picked file as base64 (answer-file `bytes` params, e.g. a lock-screen image). Max 16 MB.
#[tauri::command]
fn read_file_base64(path: String) -> Result<Value, String> {
    let p = PathBuf::from(&path);
    let meta = fs::metadata(&p).map_err(|e| format!("{path}: {e}"))?;
    if meta.len() > 16 * 1024 * 1024 {
        return Err("File is larger than 16 MB".into());
    }
    let bytes = fs::read(&p).map_err(|e| format!("read {path}: {e}"))?;
    Ok(json!({
        "name": p.file_name().map(|n| n.to_string_lossy().into_owned()),
        "sizeBytes": bytes.len(),
        "base64": base64::engine::general_purpose::STANDARD.encode(bytes),
    }))
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("Only http(s) links can be opened".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage::<RunsState>(Arc::new(Runs::default()))
        .invoke_handler(tauri::generate_handler![
            engine_run,
            engine_run_elevated,
            engine_call,
            engine_cancel,
            app_context,
            config_load,
            config_save,
            pack_read,
            pack_save,
            pack_import,
            pack_export,
            catalog_load,
            secrets_write,
            secrets_discard,
            tmp_file,
            tmp_read_text,
            tmp_save_as,
            tmp_discard,
            read_file_base64,
            open_path,
            open_url
        ])
        .run(tauri::generate_context!())
        .expect("error while running Phoenix");
}
