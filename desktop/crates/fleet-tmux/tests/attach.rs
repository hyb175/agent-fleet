//! Against a real tmux on a throwaway socket: attach, stream a pane's output,
//! get a command's reply.

use fleet_tmux::{Client, Event};
use std::process::Command;
use std::time::{Duration, Instant};

fn tmux(sock: &str, args: &[&str]) -> String {
    let out = Command::new("tmux")
        .args(["-L", sock, "-f", "/dev/null"])
        .args(args)
        .output()
        .expect("tmux runs");
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

struct Server(String);
impl Drop for Server {
    fn drop(&mut self) {
        tmux(&self.0, &["kill-server"]);
    }
}

#[test]
fn streams_output_and_replies() {
    let srv = Server(format!("fleet-tmux-test-{}", std::process::id()));
    tmux(
        &srv.0,
        &[
            "new-session",
            "-d",
            "-s",
            "w",
            "-x",
            "80",
            "-y",
            "24",
            "cat",
        ],
    );
    let pane = tmux(
        &srv.0,
        &["display-message", "-p", "-t", "=w:", "#{pane_id}"],
    );
    let id: u32 = pane.trim_start_matches('%').parse().unwrap();

    let (mut c, rx) = Client::attach(&srv.0, "w").unwrap();
    let seq = c
        .send(&[
            "display-message -p 'first'",
            &format!("display-message -p -t {pane} '#{{pane_width}}x#{{pane_height}}'"),
        ])
        .unwrap();
    c.send(&[&format!("send-keys -t {pane} -l 'hello'")])
        .unwrap();

    let (mut size, mut echoed) = (None, Vec::new());
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && (size.is_none() || !echoed.windows(5).any(|w| w == b"hello"))
    {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(Event::Reply {
                seq: s,
                ok: true,
                lines,
            }) if s == seq + 1 => size = Some(lines),
            Ok(Event::Output { pane: p, bytes }) if p == id => echoed.extend(bytes),
            Ok(Event::Exit(r)) => panic!("control client exited: {r:?}"),
            _ => {}
        }
    }
    assert_eq!(size, Some(vec![b"80x24".to_vec()]));
    assert!(
        echoed.windows(5).any(|w| w == b"hello"),
        "no echo in {:?}",
        String::from_utf8_lossy(&echoed)
    );
}
