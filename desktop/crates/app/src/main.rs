//! Fleet Desktop, first light: one read-only terminal tile showing a live
//! fleet pane through a tmux control-mode client.
//!
//!   fleet-desktop [target]   target: a pane (%12), window or session; default
//!                            is the server's current pane
//!
//! The tile renders at the pane's current size and never sends one, so a
//! terminal attached to the same window keeps owning its size.

use fleet_tmux::{Client, Event};
use gpui_kit::*;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use term::{Rgb, Tile};

const SEED_FMT: &str = "'#{cursor_x} #{cursor_y} #{pane_width} #{pane_height}'";

fn main() {
    let socket = std::env::var("AGENT_FLEET_SOCKET").unwrap_or_else(|_| "agent-fleet".into());
    let target = std::env::args().nth(1);
    let (session, pane, window) = match resolve(&socket, target.as_deref()) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("fleet-desktop: {e}");
            std::process::exit(1);
        }
    };
    let pane_n: u32 = pane[1..].parse().expect("pane id is %N");

    let (client, events) = Client::attach(&socket, &session).unwrap_or_else(|e| {
        eprintln!("fleet-desktop: cannot attach to {session} on -L {socket}: {e}");
        std::process::exit(1);
    });
    let client = Arc::new(Mutex::new(client));
    let tile = Arc::new(Mutex::new(Tile::new(80, 24)));
    let (dirty_tx, dirty_rx) = async_channel::bounded::<()>(1);

    // The reader: feeds the Term in stream order and pings the view at most
    // once per batch of events.
    let reseed = {
        let (client, pane) = (client.clone(), pane.clone());
        move || {
            client
                .lock()
                .unwrap()
                .send(&[
                    &format!("display-message -p -t {pane} {SEED_FMT}"),
                    &format!("capture-pane -p -e -t {pane}"),
                ])
                .ok()
        }
    };
    let mut pending = reseed();
    {
        let tile = tile.clone();
        thread::spawn(move || {
            let mut cursor = (0, 0);
            while let Ok(first) = events.recv() {
                for ev in std::iter::once(first).chain(events.try_iter()) {
                    match ev {
                        Event::Reply {
                            seq,
                            ok: true,
                            lines,
                        } if Some(seq) == pending => {
                            let f: Vec<usize> = lines
                                .first()
                                .map(|l| {
                                    String::from_utf8_lossy(l)
                                        .split(' ')
                                        .filter_map(|n| n.parse().ok())
                                        .collect()
                                })
                                .unwrap_or_default();
                            if let [x, y, w, h] = f[..] {
                                cursor = (x, y);
                                tile.lock().unwrap().resize(w, h);
                            }
                        }
                        Event::Reply { seq, ok, lines } if pending.map(|p| p + 1) == Some(seq) => {
                            if ok {
                                tile.lock().unwrap().seed(&lines, cursor.0, cursor.1);
                            }
                            pending = None;
                        }
                        Event::Output { pane: p, bytes } if p == pane_n && pending.is_none() => {
                            tile.lock().unwrap().feed(&bytes)
                        }
                        Event::Notification(n)
                            if n.starts_with(format!("%layout-change {window} ").as_bytes()) =>
                        {
                            pending = reseed()
                        }
                        Event::Exit(reason) => {
                            tile.lock().unwrap().feed(
                                format!("\r\n[detached: {}]", reason.unwrap_or_default())
                                    .as_bytes(),
                            );
                            let _ = dirty_tx.try_send(());
                            return;
                        }
                        _ => {}
                    }
                }
                let _ = dirty_tx.try_send(());
            }
        });
    }

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        let options = WindowOptions {
            titlebar: Some(TitlebarOptions {
                title: Some(format!("Fleet — {session} {pane}").into()),
                ..Default::default()
            }),
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(1100.), px(720.)),
                cx,
            ))),
            ..Default::default()
        };
        gpui_kit::open_window(options, cx, |_, cx| {
            cx.new(|cx| {
                cx.spawn(async move |this, cx| {
                    while dirty_rx.recv().await.is_ok() {
                        if this.update(cx, |_, cx| cx.notify()).is_err() {
                            break;
                        }
                    }
                })
                .detach();
                TileView {
                    tile,
                    _client: client,
                }
            })
        })
        .expect("open window");
        cx.activate(true);
    });
}

/// `(session, %pane, @window)` of a tmux target on the fleet socket.
fn resolve(socket: &str, target: Option<&str>) -> Result<(String, String, String), String> {
    let mut cmd = Command::new("tmux");
    cmd.args(["-L", socket, "display-message", "-p"])
        .env_remove("TMUX");
    if let Some(t) = target {
        cmd.args(["-t", t]);
    }
    let out = cmd
        .arg("#{session_name}\t#{pane_id}\t#{window_id}")
        .output()
        .map_err(|e| format!("tmux: {e}"))?;
    let line = String::from_utf8_lossy(&out.stdout).trim().to_string();
    match line.split('\t').collect::<Vec<_>>()[..] {
        [s, p, w] if !s.is_empty() => Ok((s.into(), p.into(), w.into())),
        _ => Err(format!(
            "no pane for {} on -L {socket}: {}",
            target.unwrap_or("the current pane"),
            String::from_utf8_lossy(&out.stderr).trim()
        )),
    }
}

struct TileView {
    tile: Arc<Mutex<Tile>>,
    _client: Arc<Mutex<Client>>,
}

fn hsla(c: Rgb) -> Hsla {
    rgb(((c.0 as u32) << 16) | ((c.1 as u32) << 8) | c.2 as u32).into()
}

#[cfg(target_os = "macos")]
const FONT: &str = "Menlo";
#[cfg(not(target_os = "macos"))]
const FONT: &str = "DejaVu Sans Mono";

impl Render for TileView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let screen = self.tile.lock().unwrap().screen();
        let family: SharedString = std::env::var("FLEET_DESKTOP_FONT")
            .unwrap_or_else(|_| FONT.into())
            .into();
        let lines = screen.lines.into_iter().map(|runs| {
            let text: String = runs.iter().map(|r| r.text.as_str()).collect();
            let runs = runs
                .iter()
                .map(|r| TextRun {
                    len: r.text.len(),
                    font: Font {
                        weight: if r.bold {
                            FontWeight::BOLD
                        } else {
                            FontWeight::NORMAL
                        },
                        style: if r.italic {
                            FontStyle::Italic
                        } else {
                            FontStyle::Normal
                        },
                        ..font(family.clone())
                    },
                    color: hsla(r.fg),
                    background_color: (r.bg != term::BG).then(|| hsla(r.bg)),
                    underline: r.underline.then(|| UnderlineStyle {
                        thickness: px(1.),
                        color: None,
                        wavy: false,
                    }),
                    strikethrough: None,
                })
                .collect();
            div()
                .h(px(17.))
                .whitespace_nowrap()
                .child(StyledText::new(text).with_runs(runs))
        });
        div()
            .size_full()
            .overflow_hidden()
            .bg(hsla(term::BG))
            .p_2()
            .font_family(family.clone())
            .text_size(px(13.))
            .line_height(px(17.))
            .children(lines)
    }
}
