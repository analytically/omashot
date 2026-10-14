//! Own the clipboard selection for one screenshot, offering several
//! representations of it.
//!
//! `wl-copy` advertises one MIME type per invocation — passing --type twice
//! keeps only the last — so a copy had to be either the image or the path. A
//! Wayland selection can carry several representations at once and the paster
//! picks the one it understands, which is what this offers:
//!
//!   image/png                       the shot            (agents, chat, editors)
//!   text/plain                      the real path       (shells, codex -i)
//!   text/uri-list                   a snapshot file     (file managers, chat)
//!   x-special/gnome-copied-files    the same, for Nautilus
//!   application/x-kde-cutselection  and for Dolphin
//!
//! The file representations point at a *snapshot*, never at the shot itself: an
//! edit, a rename or a delete of the original must not leave a pasted file
//! dangling. The path stays the real one, because that is what a command wants.
//!
//! Written against `zwlr_data_control_v1` directly, so no toolkit is involved
//! and the compositor's `cancelled` event ends ownership — no polling.
//!
//!   snapmenu-clipboard <image-path>
//!   snapmenu-clipboard <image-path> --path-only
//!   snapmenu-clipboard <image-path> --temporary

use std::env;
use std::fs::{self, File};
use std::io::Write;
use std::os::fd::OwnedFd;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use wayland_client::event_created_child;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_device_v1::{
    EVT_DATA_OFFER_OPCODE, EVT_SELECTION_OPCODE, Event as DeviceEvent, ZwlrDataControlDeviceV1,
};
use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_manager_v1::{
    Event as ManagerEvent, ZwlrDataControlManagerV1,
};
use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_offer_v1::{
    Event as OfferEvent, ZwlrDataControlOfferV1,
};
use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_source_v1::{
    Event as SourceEvent, ZwlrDataControlSourceV1,
};

/// How many snapshots to keep around. A pasted file should stay available for
/// long enough to be used, without the directory growing forever.
const SNAPSHOTS_KEPT: usize = 10;

struct Clipboard {
    png: Vec<u8>,
    path: Option<String>,
    uri: String,
    gnome: String,
    finished: bool,
}

impl Clipboard {
    fn payload(&self, mime: &str) -> Option<&[u8]> {
        match mime {
            "image/png" => Some(&self.png),
            "text/plain" => self.path.as_ref().map(|path| path.as_bytes()),
            "text/uri-list" => Some(self.uri.as_bytes()),
            "x-special/gnome-copied-files" => Some(self.gnome.as_bytes()),
            "application/x-kde-cutselection" => Some(b"0"),
            _ => None,
        }
    }

    fn send(&self, mime: &str, fd: OwnedFd) {
        let Some(bytes) = self.payload(mime) else {
            return;
        };
        // A pasting client that goes away must not kill the owner, so write
        // errors (EPIPE included, since Rust ignores SIGPIPE) are not fatal.
        let mut file = File::from(fd);
        let _ = file.write_all(bytes);
        let _ = file.flush();
    }
}

impl Dispatch<ZwlrDataControlSourceV1, ()> for Clipboard {
    fn event(
        state: &mut Self,
        _source: &ZwlrDataControlSourceV1,
        event: SourceEvent,
        _data: &(),
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            SourceEvent::Send { mime_type, fd } => state.send(&mime_type, fd),
            // Some other client took the selection: ownership is over.
            SourceEvent::Cancelled => state.finished = true,
            _ => {}
        }
    }
}

impl Dispatch<ZwlrDataControlDeviceV1, ()> for Clipboard {
    fn event(
        state: &mut Self,
        _device: &ZwlrDataControlDeviceV1,
        event: DeviceEvent,
        _data: &(),
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            DeviceEvent::Finished => state.finished = true,
            // Offers from other clients are of no interest: this process only
            // serves its own selection. The offer objects they carry still have
            // to be created, which is what the macro below declares.
            _ => {}
        }
    }

    event_created_child!(Clipboard, ZwlrDataControlDeviceV1, [
        EVT_DATA_OFFER_OPCODE => (ZwlrDataControlOfferV1, ()),
        EVT_SELECTION_OPCODE => (ZwlrDataControlOfferV1, ()),
    ]);
}

impl Dispatch<ZwlrDataControlOfferV1, ()> for Clipboard {
    fn event(
        _state: &mut Self,
        _offer: &ZwlrDataControlOfferV1,
        _event: OfferEvent,
        _data: &(),
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrDataControlManagerV1, ()> for Clipboard {
    fn event(
        _state: &mut Self,
        _manager: &ZwlrDataControlManagerV1,
        _event: ManagerEvent,
        _data: &(),
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for Clipboard {
    fn event(
        _state: &mut Self,
        _seat: &wl_seat::WlSeat,
        _event: wl_seat::Event,
        _data: &(),
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Clipboard {
    fn event(
        _state: &mut Self,
        _registry: &wl_registry::WlRegistry,
        _event: wl_registry::Event,
        _data: &GlobalListContents,
        _conn: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

fn state_home() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// A copy of the shot for the file representations, so the pasted file cannot
/// dangle when the original is edited, renamed or deleted.
fn snapshot(source: &Path, data: &[u8]) -> std::io::Result<PathBuf> {
    let root = state_home().join("snapmenu/clipboard");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let folder = root.join(format!("{stamp}-{}", std::process::id()));
    // Screen content: the snapshot tree is owner-only whatever the umask is,
    // and a tree created by an older run (or another tool) is corrected too.
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(&folder)?;
    let _ = fs::set_permissions(&root, fs::Permissions::from_mode(0o700));
    let name = source
        .file_name()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("screenshot.png"));
    let target = folder.join(name);
    fs::write(&target, data)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o600))?;
    prune(&root, SNAPSHOTS_KEPT);
    Ok(target)
}

/// Keep the newest snapshots, by the timestamp in their directory name.
fn prune(root: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let mut folders: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    folders.sort();
    while folders.len() > keep {
        let oldest = folders.remove(0);
        let _ = fs::remove_dir_all(oldest);
    }
}

/// `file:///…`, with everything outside the URI's unreserved set percent-encoded
/// (a screenshot in `~/My Pictures` has to survive the trip).
fn file_uri(path: &Path) -> String {
    let mut uri = String::from("file://");
    for byte in path.to_string_lossy().bytes() {
        let plain =
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/');
        if plain {
            uri.push(byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    uri
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        return Err("usage: snapmenu-clipboard <image-path> [--path-only] [--temporary]".into());
    }
    let flags = &args[2..];
    let path_only = flags.iter().any(|flag| flag == "--path-only");
    let temporary = flags.iter().any(|flag| flag == "--temporary");

    let source = PathBuf::from(&args[1]);
    let source = source.canonicalize().unwrap_or(source);
    let data = fs::read(&source).map_err(|error| format!("{}: {error}", source.display()))?;

    // The file representations come from the snapshot; text/plain keeps the
    // real path, unless the shot is temporary and the file is about to go.
    let snapshot_path = if path_only {
        None
    } else {
        snapshot(&source, &data).ok()
    };
    let uri = snapshot_path
        .as_ref()
        .map(|path| format!("{}\r\n", file_uri(path)))
        .unwrap_or_default();
    let gnome = snapshot_path
        .as_ref()
        .map(|path| format!("copy\n{}", file_uri(path)))
        .unwrap_or_default();

    // The temporary source is deleted once the clipboard has actually taken the
    // selection — further down, after the Wayland handshake. Deleting it here meant a
    // failed handshake lost the file, left nothing on the clipboard, and still
    // reported success to the caller.
    let state = Clipboard {
        png: if path_only { Vec::new() } else { data },
        path: if temporary {
            None
        } else {
            Some(source.display().to_string())
        },
        uri,
        gnome,
        finished: false,
    };
    // A clipboard with nothing on it would be worse than none at all.
    if state.path.is_none() && state.uri.is_empty() && state.png.is_empty() {
        return Err("nothing to copy".into());
    }

    let mut state = state;
    let connection =
        Connection::connect_to_env().map_err(|error| format!("no Wayland session: {error}"))?;
    let (globals, mut queue) = registry_queue_init::<Clipboard>(&connection)
        .map_err(|error| format!("registry: {error}"))?;
    if temporary {
        // Past the point where the run can fail for want of a session or a protocol.
        let _ = fs::remove_file(&source);
    }
    let qh = queue.handle();
    // v1 is enough: primary selection is not something this helper serves.
    let manager: ZwlrDataControlManagerV1 = globals
        .bind(&qh, 1..=1, ())
        .map_err(|_| "the compositor does not offer wlr-data-control".to_string())?;
    let seat: wl_seat::WlSeat = globals
        .bind(&qh, 1..=1, ())
        .map_err(|error| format!("seat: {error}"))?;

    let source_object = manager.create_data_source(&qh, ());
    if !path_only {
        source_object.offer("image/png".into());
    }
    if state.path.is_some() {
        source_object.offer("text/plain".into());
    }
    if !state.uri.is_empty() {
        for mime in [
            "text/uri-list",
            "x-special/gnome-copied-files",
            "application/x-kde-cutselection",
        ] {
            source_object.offer(mime.into());
        }
    }

    let device = manager.get_data_device(&seat, &qh, ());
    device.set_selection(Some(&source_object));
    queue
        .roundtrip(&mut state)
        .map_err(|error| format!("roundtrip: {error}"))?;

    while !state.finished {
        if queue.blocking_dispatch(&mut state).is_err() {
            break;
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("snapmenu-clipboard: {message}");
            ExitCode::FAILURE
        }
    }
}
