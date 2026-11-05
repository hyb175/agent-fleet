//! Fleet Desktop: read-only terminal tiles over live fleet panes, through one
//! tmux control-mode client per session.
//!
//!   fleet-desktop [target …]   each target a pane (%12), window or session;
//!                              default is the server's current pane
//!
//! FLEET_DESKTOP_STATS=<secs> prints frame timing after <secs> and quits.

mod session;
mod stats;
mod tile;

use gpui_kit::*;
use stats::Stats;
use std::cell::RefCell;
use std::process::Command;
use std::rc::Rc;
use std::time::Duration;
use tile::TileView;

fn main() {
    let socket = std::env::var("AGENT_FLEET_SOCKET").unwrap_or_else(|_| "agent-fleet".into());
    let mut targets: Vec<Option<String>> = std::env::args().skip(1).map(Some).collect();
    if targets.is_empty() {
        targets.push(None);
    }
    let fail = |e: String| -> ! {
        eprintln!("fleet-desktop: {e}");
        std::process::exit(1)
    };

    // Group panes by session, keeping the targets' order for the grid.
    let mut sessions: Vec<(String, Vec<(String, String)>)> = Vec::new();
    let mut order = Vec::new();
    for t in &targets {
        let (s, p, w) = resolve(&socket, t.as_deref()).unwrap_or_else(|e| fail(e));
        let i = sessions
            .iter()
            .position(|(n, _)| *n == s)
            .unwrap_or_else(|| {
                sessions.push((s.clone(), Vec::new()));
                sessions.len() - 1
            });
        order.push((i, sessions[i].1.len()));
        sessions[i].1.push((p, w));
    }
    let feeds: Vec<Vec<session::Feed>> = sessions
        .iter()
        .map(|(s, panes)| {
            session::attach(&socket, s, panes)
                .unwrap_or_else(|e| fail(format!("cannot attach to {s} on -L {socket}: {e}")))
        })
        .collect();
    let mut feeds: Vec<Vec<Option<session::Feed>>> = feeds
        .into_iter()
        .map(|v| v.into_iter().map(Some).collect())
        .collect();
    let feeds: Vec<session::Feed> = order
        .iter()
        .map(|&(s, k)| feeds[s][k].take().expect("each pane once"))
        .collect();
    let title = format!(
        "Fleet — {}",
        sessions
            .iter()
            .map(|(s, _)| s.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    let stats_secs: Option<f64> = std::env::var("FLEET_DESKTOP_STATS")
        .ok()
        .and_then(|s| s.parse().ok());

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        let options = WindowOptions {
            titlebar: Some(TitlebarOptions {
                title: Some(title.into()),
                ..Default::default()
            }),
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(1400.), px(900.)),
                cx,
            ))),
            ..Default::default()
        };
        let stats = stats_secs.map(|_| Rc::new(RefCell::new(Stats::default())));
        gpui_kit::open_window(options, cx, |_, cx| {
            let tiles = feeds
                .into_iter()
                .map(|(pane, dirty)| cx.new(|cx| TileView::new(pane, dirty, stats.clone(), cx)))
                .collect();
            cx.new(|_| Grid {
                tiles,
                stats: stats.clone(),
            })
        })
        .expect("open window");
        if let (Some(secs), Some(stats)) = (stats_secs, stats) {
            cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(Duration::from_secs_f64(secs))
                    .await;
                println!("{}", stats.borrow_mut().report());
                cx.update(|cx| cx.quit());
            })
            .detach();
        }
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

/// The tiles in a near-square grid.
struct Grid {
    tiles: Vec<Entity<TileView>>,
    stats: Option<Rc<RefCell<Stats>>>,
}

impl Render for Grid {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        if let Some(s) = &self.stats {
            s.borrow_mut().frame();
        }
        let cols = (self.tiles.len() as f32).sqrt().ceil().max(1.) as usize;
        div()
            .size_full()
            .flex()
            .flex_col()
            .gap_px()
            .bg(rgb(0x000000))
            .children(self.tiles.chunks(cols).map(|row| {
                div()
                    .flex()
                    .flex_1()
                    .gap_px()
                    // Cached: a tile that did not change reuses its last frame.
                    .children(row.iter().map(|t| {
                        div()
                            .flex_1()
                            .overflow_hidden()
                            .child(t.clone().cached(StyleRefinement::default().size_full()))
                    }))
            }))
    }
}
