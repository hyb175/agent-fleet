//! One control-mode client per tmux session, feeding the `Term` of every tile
//! that shows one of its panes.

use fleet_tmux::{Client, Event};
use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Mutex};
use std::thread;
use term::Tile;

const SEED_FMT: &str = "'#{cursor_x} #{cursor_y} #{pane_width} #{pane_height}'";

pub struct Pane {
    pub tile: Tile,
    id: String,
    window: String,
    /// The first `seq` of an in-flight seed; output is dropped until it lands,
    /// because everything before the capture's reply is already in the capture.
    pending: Option<u64>,
    cursor: (usize, usize),
}

/// A tile's screen and the signal that it changed (at most one queued).
pub type Feed = (Arc<Mutex<Pane>>, async_channel::Receiver<()>);

/// Attach to `session` and stream `panes` (`(%pane, @window)`), each seeded first.
pub fn attach(socket: &str, session: &str, panes: &[(String, String)]) -> io::Result<Vec<Feed>> {
    let (client, events) = Client::attach(socket, session)?;
    let client = Arc::new(Mutex::new(client));
    let mut routes = HashMap::new();
    let mut feeds = Vec::new();
    for (id, window) in panes {
        let n: u32 = id[1..]
            .parse()
            .map_err(|_| io::Error::other(format!("bad pane id {id}")))?;
        let pane = Arc::new(Mutex::new(Pane {
            tile: Tile::new(80, 24),
            id: id.clone(),
            window: window.clone(),
            pending: None,
            cursor: (0, 0),
        }));
        reseed(&client, &mut pane.lock().unwrap());
        let (tx, rx) = async_channel::bounded(1);
        routes.insert(n, (pane.clone(), tx));
        feeds.push((pane, rx));
    }
    thread::spawn(move || {
        while let Ok(first) = events.recv() {
            let mut touched = Vec::new();
            for ev in std::iter::once(first).chain(events.try_iter()) {
                match ev {
                    Event::Output { pane, bytes } => {
                        if let Some((p, _)) = routes.get(&pane) {
                            let mut p = p.lock().unwrap();
                            if p.pending.is_none() {
                                p.tile.feed(&bytes);
                                touched.push(pane);
                            }
                        }
                    }
                    Event::Reply { seq, ok, lines } => {
                        for (n, (p, _)) in &routes {
                            let mut p = p.lock().unwrap();
                            let Some(first) = p.pending else { continue };
                            if seq == first && ok {
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
                                    p.cursor = (x, y);
                                    p.tile.resize(w, h);
                                }
                            } else if seq == first + 1 {
                                if ok {
                                    let (x, y) = p.cursor;
                                    p.tile.seed(&lines, x, y);
                                }
                                p.pending = None;
                                touched.push(*n);
                            }
                        }
                    }
                    Event::Notification(line) => {
                        // `%layout-change @W …`: a pane in W may have a new size.
                        let mut words = line.split(|&b| b == b' ');
                        if words.next() == Some(b"%layout-change") {
                            let w = words.next().unwrap_or_default();
                            for (p, _) in routes.values() {
                                let mut p = p.lock().unwrap();
                                if p.window.as_bytes() == w {
                                    reseed(&client, &mut p);
                                }
                            }
                        }
                    }
                    Event::Exit(reason) => {
                        for (n, (p, _)) in &routes {
                            p.lock().unwrap().tile.feed(
                                format!("\r\n[detached: {}]", reason.clone().unwrap_or_default())
                                    .as_bytes(),
                            );
                            touched.push(*n);
                        }
                        ping(&routes, &touched);
                        return;
                    }
                }
            }
            ping(&routes, &touched);
        }
    });
    Ok(feeds)
}

fn reseed(client: &Mutex<Client>, p: &mut Pane) {
    let id = &p.id;
    p.pending = client
        .lock()
        .unwrap()
        .send(&[
            &format!("display-message -p -t {id} {SEED_FMT}"),
            &format!("capture-pane -p -e -t {id}"),
        ])
        .ok();
}

fn ping(routes: &HashMap<u32, (Arc<Mutex<Pane>>, async_channel::Sender<()>)>, touched: &[u32]) {
    for n in touched {
        if let Some((_, tx)) = routes.get(n) {
            let _ = tx.try_send(());
        }
    }
}
