use adtention_terminal::{
    checksum_for_asset, mark_render_seen, parse_release_info, platform_asset_name, refresh_once,
    release_asset_url, release_is_newer, render_ad, resolve_open_url, sha256_hex, HttpClient,
    RefreshConfig, RUNTIME_ASSET_NAME,
};
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DEFAULT_UPDATE_API: &str =
    "https://api.github.com/repos/adtention-ai/terminal/releases/latest";
const CHECKSUMS_ASSET_NAME: &str = "SHA256SUMS";

struct CurlHttp;

impl HttpClient for CurlHttp {
    fn post(&self, url: &str, body: Option<&str>) -> Result<String, String> {
        let mut cmd = Command::new("curl");
        cmd.args(["-s", "-m", "5", "-X", "POST", url]);
        if let Some(body) = body {
            cmd.args(["-H", "content-type: application/json", "-d", body]);
        }
        let output = cmd.output().map_err(|err| err.to_string())?;
        if !output.status.success() {
            return Err(format!("curl exited with {}", output.status));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }
}

fn main() {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage_and_exit();
    };

    let code = match command.as_str() {
        "setup" => setup().map(|_| 0).unwrap_or(0),
        "refresh" => {
            let cwd = args
                .next()
                .map(PathBuf::from)
                .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
            refresh(cwd).map(|_| 0).unwrap_or(0)
        }
        "render" => render().map(|_| 0).unwrap_or(0),
        "mark-display" | "mark-render" => mark_render_seen(&prepare_cache_dir(), SystemTime::now())
            .map(|_| 0)
            .unwrap_or(0),
        "title-daemon" => {
            let interval = parse_env_u64("ADTENTION_TITLE_INTERVAL", 15).max(5);
            title_daemon(interval).map(|_| 0).unwrap_or(0)
        }
        "learn-more" | "open" => {
            let target = args.next();
            learn_more(target).map(|_| 0).unwrap_or(1)
        }
        "update" => self_update().map(|_| 0).unwrap_or(1),
        "doctor" => doctor().map(|_| 0).unwrap_or(1),
        _ => {
            eprintln!("unknown command: {command}");
            2
        }
    };
    std::process::exit(code);
}

fn setup() -> io::Result<()> {
    let cache = prepare_cache_dir();
    fs::create_dir_all(&cache)?;
    write_if_missing(cache.join("balance_display"), "⊕ $0.00")?;
    write_if_missing(cache.join("title.txt"), "⊕ $0.00")?;
    write_if_missing(cache.join("prompt_line.txt"), "⊕ $0.00")?;
    write_if_missing(cache.join("terminal.txt"), "⊕ $0.00\n⊕ $0.00\n")?;
    Ok(())
}

fn refresh(cwd: PathBuf) -> io::Result<()> {
    let mut event_input = String::new();
    let _ = io::stdin().read_to_string(&mut event_input);
    let config = RefreshConfig {
        cache_dir: prepare_cache_dir(),
        api_base: env::var("ADTENTION_API")
            .unwrap_or_else(|_| "https://api.adtention.ai".to_string()),
        cwd,
        event_input,
        display_ttl_secs: parse_env_u64("ADTENTION_DISPLAY_TTL", 120),
        min_dwell_secs: parse_env_u64("ADTENTION_MIN_DWELL", 15),
        now: SystemTime::now(),
    };
    let _ = refresh_once(&config, &CurlHttp);
    Ok(())
}

fn render() -> io::Result<()> {
    let cache = prepare_cache_dir();
    let balance =
        fs::read_to_string(cache.join("balance_display")).unwrap_or_else(|_| "⊕ $0.00".to_string());
    let ad = fs::read_to_string(cache.join("current_ad.txt")).ok();
    let max_width = parse_env_usize("ADTENTION_MAX_WIDTH", columns().unwrap_or(120));
    let rendered = render_ad(&balance, ad.as_deref(), 80, max_width);
    fs::write(cache.join("title.txt"), &rendered.title).ok();
    fs::write(cache.join("prompt_line.txt"), &rendered.prompt_line).ok();
    fs::write(
        cache.join("terminal.txt"),
        format!("{}\n{}\n", rendered.title, rendered.prompt_line),
    )
    .ok();
    mark_render_seen(&cache, SystemTime::now()).ok();
    println!("{}", rendered.prompt_line);
    Ok(())
}

fn title_daemon(interval_secs: u64) -> io::Result<()> {
    let cache = prepare_cache_dir();
    loop {
        let title = fs::read_to_string(cache.join("title.txt"))
            .or_else(|_| fs::read_to_string(cache.join("balance_display")))
            .unwrap_or_else(|_| "⊕ $0.00".to_string());
        let title = title.trim();
        if !title.is_empty() {
            print!("\x1b]0;{title}\x07");
            let _ = io::stdout().flush();
        }
        thread::sleep(Duration::from_secs(interval_secs));
    }
}

fn learn_more(target: Option<String>) -> io::Result<()> {
    let raw_url = match target {
        Some(url) => url,
        None => {
            fs::read_to_string(prepare_cache_dir().join("current_click.txt")).unwrap_or_default()
        }
    };
    let api = env::var("ADTENTION_API").unwrap_or_else(|_| "https://api.adtention.ai".to_string());
    let Some(url) = resolve_open_url(&raw_url, &api) else {
        if raw_url.trim().is_empty() {
            println!("adtention: no sponsor to open yet. Run a command, then try again.");
        } else {
            println!("adtention: refusing to open an unsupported URL.");
        }
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid URL"));
    };
    open_url(&url)?;
    println!("adtention: opened the sponsor in your browser.");
    Ok(())
}

fn self_update() -> io::Result<()> {
    let release_api =
        env::var("ADTENTION_UPDATE_API").unwrap_or_else(|_| DEFAULT_UPDATE_API.to_string());
    let release_body = download_bytes(&release_api)?;
    let release_body = String::from_utf8_lossy(&release_body);
    let release = parse_release_info(&release_body)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid release response"))?;
    let current_version = env::var("ADTENTION_UPDATE_CURRENT_VERSION")
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());

    if !release_is_newer(&release.tag_name, &current_version) {
        println!(
            "adtention: already up to date (current {}, latest {}).",
            current_version, release.tag_name
        );
        return Ok(());
    }

    let asset_name = current_platform_asset_name()?;
    let checksums_url = release_asset_url(&release, CHECKSUMS_ASSET_NAME).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "release is missing SHA256SUMS asset",
        )
    })?;
    let checksums_bytes = download_bytes(checksums_url)?;
    let checksums = String::from_utf8_lossy(&checksums_bytes);

    let install_root = update_install_root();
    let tmp_dir = update_tmp_dir();
    fs::create_dir_all(&tmp_dir)?;
    fs::create_dir_all(install_root.join("bin"))?;

    let runtime_bytes = match release_asset_url(&release, RUNTIME_ASSET_NAME) {
        Some(runtime_url) => {
            let bytes = download_bytes(runtime_url)?;
            verify_asset_bytes(RUNTIME_ASSET_NAME, &bytes, &checksums)?;
            Some(bytes)
        }
        None => {
            println!("adtention: release has no runtime package; updating binary only.");
            None
        }
    };
    let asset_url = release_asset_url(&release, &asset_name).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("release is missing {asset_name}"),
        )
    })?;
    let binary_bytes = download_bytes(asset_url)?;
    verify_asset_bytes(&asset_name, &binary_bytes, &checksums)?;

    if let Some(runtime_bytes) = runtime_bytes {
        install_runtime_package(&install_root, &tmp_dir, &runtime_bytes)?;
    }
    install_platform_binary(&install_root.join("bin").join(&asset_name), &binary_bytes)?;
    fs::write(
        install_root.join("bin").join(CHECKSUMS_ASSET_NAME),
        &checksums_bytes,
    )?;

    reinstall_shell_integration(&install_root)?;
    println!("adtention: updated to {}.", release.tag_name);
    Ok(())
}

fn current_platform_asset_name() -> io::Result<String> {
    platform_asset_name(env::consts::OS, env::consts::ARCH).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::Unsupported,
            format!(
                "unsupported platform: {} {}",
                env::consts::OS,
                env::consts::ARCH
            ),
        )
    })
}

fn download_bytes(url: &str) -> io::Result<Vec<u8>> {
    let output = Command::new("curl")
        .args(["-fsSL", "-m", "30"])
        .arg(url)
        .output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(io::Error::other(format!(
            "curl failed for {url}: {}",
            stderr.trim()
        )));
    }
    Ok(output.stdout)
}

fn verify_asset_bytes(asset_name: &str, bytes: &[u8], checksums: &str) -> io::Result<()> {
    let expected = checksum_for_asset(checksums, asset_name).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("SHA256SUMS does not list {asset_name}"),
        )
    })?;
    let actual = sha256_hex(bytes);
    if expected != actual {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("checksum mismatch for {asset_name}"),
        ));
    }
    Ok(())
}

fn update_install_root() -> PathBuf {
    if let Some(root) = env::var_os("ADTENTION_INSTALL_ROOT").map(PathBuf::from) {
        return root;
    }

    if let Ok(exe) = env::current_exe() {
        if let Some(parent) = exe.parent() {
            if parent.file_name().and_then(|name| name.to_str()) == Some("bin") {
                if let Some(root) = parent.parent() {
                    return root.to_path_buf();
                }
            }
        }
    }

    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn update_tmp_dir() -> PathBuf {
    env::temp_dir().join(format!("adtention-terminal-update-{}", std::process::id()))
}

fn install_runtime_package(
    install_root: &Path,
    tmp_dir: &Path,
    runtime_bytes: &[u8],
) -> io::Result<()> {
    fs::create_dir_all(install_root)?;
    let package_path = tmp_dir.join(RUNTIME_ASSET_NAME);
    fs::write(&package_path, runtime_bytes)?;

    let output = Command::new("tar")
        .arg("-xzf")
        .arg(&package_path)
        .arg("-C")
        .arg(install_root)
        .output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(io::Error::other(format!(
            "failed to extract runtime package: {}",
            stderr.trim()
        )));
    }
    Ok(())
}

fn install_platform_binary(destination: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = destination.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "binary destination has no parent directory",
        )
    })?;
    fs::create_dir_all(parent)?;
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("adtention-terminal");
    let tmp_path = parent.join(format!("{file_name}.update-{}", std::process::id()));
    fs::write(&tmp_path, bytes)?;
    set_executable(&tmp_path)?;
    replace_file(&tmp_path, destination)
}

#[cfg(unix)]
fn set_executable(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions)
}

#[cfg(not(unix))]
fn set_executable(_path: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(tmp_path: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(tmp_path, destination)
}

#[cfg(windows)]
fn replace_file(tmp_path: &Path, destination: &Path) -> io::Result<()> {
    let direct = (|| {
        if destination.exists() {
            fs::remove_file(destination)?;
        }
        fs::rename(tmp_path, destination)
    })();
    if direct.is_ok() {
        return Ok(());
    }

    schedule_windows_replace(tmp_path, destination)
}

#[cfg(windows)]
fn schedule_windows_replace(tmp_path: &Path, destination: &Path) -> io::Result<()> {
    let script = format!(
        "$ErrorActionPreference='Stop'; for ($i=0; $i -lt 40; $i++) {{ try {{ Move-Item -LiteralPath {} -Destination {} -Force; exit 0 }} catch {{ Start-Sleep -Milliseconds 250 }} }} exit 1",
        powershell_literal(&tmp_path.display().to_string()),
        powershell_literal(&destination.display().to_string())
    );
    let shell = if Command::new("pwsh")
        .arg("-NoProfile")
        .arg("-Command")
        .arg("$PSVersionTable")
        .output()
        .is_ok()
    {
        "pwsh"
    } else {
        "powershell"
    };
    Command::new(shell)
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"])
        .arg(script)
        .spawn()?;
    println!("adtention: Windows will finish replacing the binary after this process exits.");
    Ok(())
}

#[cfg(windows)]
fn powershell_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn reinstall_shell_integration(install_root: &Path) -> io::Result<()> {
    let sh_installer = install_root
        .join("scripts")
        .join("install-shell-integration.sh");

    #[cfg(windows)]
    {
        let ps_installer = install_root
            .join("scripts")
            .join("install-shell-integration.ps1");
        if ps_installer.exists() {
            let shell = if Command::new("pwsh")
                .arg("-NoProfile")
                .arg("-Command")
                .arg("$PSVersionTable")
                .output()
                .is_ok()
            {
                "pwsh"
            } else {
                "powershell"
            };
            let status = Command::new(shell)
                .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
                .arg(&ps_installer)
                .env("ADTENTION_INSTALL_ROOT", install_root)
                .status()?;
            if !status.success() {
                return Err(io::Error::other("PowerShell integration reinstall failed"));
            }
            return Ok(());
        }
    }

    if sh_installer.exists() {
        let status = Command::new("sh")
            .arg(&sh_installer)
            .env("ADTENTION_INSTALL_ROOT", install_root)
            .status()?;
        if !status.success() {
            return Err(io::Error::other("shell integration reinstall failed"));
        }
    }
    Ok(())
}

fn doctor() -> io::Result<()> {
    let cache = prepare_cache_dir();
    println!("adtention doctor");
    println!("cache: {}", cache.display());
    println!("client: {}", current_exe_display());
    println!(
        "last_render_seen: {}",
        age_display(&cache.join("last_render_seen"))
    );
    println!("last_serve: {}", age_display(&cache.join("last_serve")));
    if let Ok(reason) = fs::read_to_string(cache.join("last_skipped")) {
        println!("last_skipped: {}", reason.trim());
    }
    Ok(())
}

fn open_url(url: &str) -> io::Result<()> {
    if let Some(program) = env::var_os("ADTENTION_OPEN_COMMAND") {
        return Command::new(program).arg(url).status().map(|_| ());
    }
    #[cfg(target_os = "macos")]
    {
        return Command::new("open").arg(url).status().map(|_| ());
    }
    #[cfg(target_os = "windows")]
    {
        return Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", url])
            .status()
            .map(|_| ());
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        return Command::new("xdg-open").arg(url).status().map(|_| ());
    }
    #[allow(unreachable_code)]
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "unsupported platform",
    ))
}

fn cache_dir() -> PathBuf {
    env::var_os("ADTENTION_CACHE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = env::var_os("HOME")
                .or_else(|| env::var_os("USERPROFILE"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."));
            let claude_cache = home.join(".claude").join("adtention");
            if claude_cache.exists() {
                claude_cache
            } else {
                home.join(".adtention")
            }
        })
}

fn prepare_cache_dir() -> PathBuf {
    let cache = cache_dir();
    migrate_legacy_cache(&cache);
    cache
}

fn migrate_legacy_cache(cache: &Path) {
    let Some(home) = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
    else {
        return;
    };

    for legacy in [
        home.join(".codex").join("adtention"),
        home.join(".adtention").join("terminal"),
    ] {
        if legacy == cache || !legacy.is_dir() {
            continue;
        }
        let _ = fs::create_dir_all(cache);
        for file in [
            "identity.json",
            "balance",
            "balance_display",
            "current_ad.txt",
            "current_click.txt",
            "title.txt",
            "prompt_line.txt",
            "terminal.txt",
            "category.txt",
            "source.txt",
            "ref",
        ] {
            let from = legacy.join(file);
            let to = cache.join(file);
            if from.exists() && !to.exists() {
                let _ = fs::copy(from, to);
            }
        }
    }
}

fn write_if_missing(path: PathBuf, contents: &str) -> io::Result<()> {
    if !path.exists() {
        fs::write(path, contents)?;
    }
    Ok(())
}

fn parse_env_u64(name: &str, default: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

fn parse_env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

fn columns() -> Option<usize> {
    env::var("COLUMNS").ok().and_then(|s| s.parse().ok())
}

fn current_exe_display() -> String {
    env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn age_display(path: &Path) -> String {
    let Ok(contents) = fs::read_to_string(path) else {
        return "missing".to_string();
    };
    let Ok(secs) = contents.trim().parse::<u64>() else {
        return "present".to_string();
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}s ago", now.saturating_sub(secs))
}

fn print_usage_and_exit() -> ! {
    eprintln!(
        "usage: adtention-terminal <setup|refresh|render|mark-render|title-daemon|learn-more|update|doctor>"
    );
    std::process::exit(2);
}
