//! P4: a tile seeded mid-stream from tmux (capture plus replayed modes) must
//! match a `Term` that saw the pane's whole byte stream: same modes (so input
//! is encoded the same), same screen, same cursor. The streams set the modes
//! claude and Neovim were seen using in a live fleet.

use fleet_tmux::{Client, Event};
use std::process::Command;
use std::time::{Duration, Instant};
use term::{Mode, PaneState, SEED_FORMAT, Tile};

fn tmux(sock: &str, args: &[&str]) -> String {
    let out = Command::new("tmux")
        .env("SHELL", "/bin/sh")
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

const MODES: Mode = Mode::ALT_SCREEN
    .union(Mode::SHOW_CURSOR)
    .union(Mode::INSERT)
    .union(Mode::APP_CURSOR)
    .union(Mode::APP_KEYPAD)
    .union(Mode::MOUSE_MODE)
    .union(Mode::SGR_MOUSE)
    .union(Mode::LINE_WRAP);

fn text(t: &Tile) -> Vec<String> {
    t.screen()
        .lines
        .iter()
        .map(|l| {
            l.iter()
                .map(|r| r.text.as_str())
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn check(name: &str, stream: &str) {
    let srv = Server(format!("term-seed-{}-{name}", std::process::id()));
    // printf turns the \033 escapes into bytes; the pane then idles.
    tmux(
        &srv.0,
        &[
            "new-session",
            "-d",
            "-s",
            "w",
            "-x",
            "60",
            "-y",
            "12",
            &format!("printf '{stream}'; exec sleep 60"),
        ],
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while tmux(
        &srv.0,
        &[
            "display-message",
            "-p",
            "-t",
            "=w:",
            "#{pane_current_command}",
        ],
    ) != "sleep"
    {
        assert!(Instant::now() < deadline, "{name}: stream never finished");
        std::thread::sleep(Duration::from_millis(50));
    }

    let mut reference = Tile::new(60, 12);
    let bytes = Command::new("printf").arg(stream).output().unwrap().stdout;
    reference.feed(&bytes);

    let (mut c, rx) = Client::attach(&srv.0, "w").unwrap();
    let first = c
        .send(&[
            &format!("display-message -p -t =w: '{SEED_FORMAT}'"),
            "capture-pane -p -e -t =w:",
        ])
        .unwrap();
    let (mut state, mut lines) = (None, None);
    while lines.is_none() {
        match rx
            .recv_timeout(Duration::from_secs(10))
            .expect("seed replies")
        {
            Event::Reply {
                seq,
                ok: true,
                lines: l,
            } if seq == first => state = PaneState::parse(&l[0]),
            Event::Reply {
                seq,
                ok: true,
                lines: l,
            } if seq == first + 1 => lines = Some(l),
            _ => {}
        }
    }
    let mut seeded = Tile::new(80, 24);
    seeded.seed(&state.expect("state parses"), &lines.unwrap());

    assert_eq!(
        seeded.mode() & MODES,
        reference.mode() & MODES,
        "{name}: modes"
    );
    assert_eq!(text(&seeded), text(&reference), "{name}: screen");
    assert_eq!(seeded.cursor(), reference.cursor(), "{name}: cursor");
}

#[test]
fn claude_like_alt_screen_with_all_motion_sgr_mouse() {
    check(
        "claude",
        r"history line\r\n\033[?1049h\033[?1003h\033[?1006h\033[2J\033[H\033[1;38;5;174m* Thinking\033[0m\r\n  reply text\r\n\033[7m> \033[0m",
    );
}

#[test]
fn nvim_like_keypad_button_mouse_and_bar_cursor() {
    check(
        "nvim",
        r"\033[?1049h\033[?1h\033=\033[?1002h\033[?1006h\033[6 q\033[H\033[2Jfn main() {}\r\n~\r\n~\033[1;4H",
    );
}

#[test]
fn shell_like_hidden_cursor_insert_and_no_wrap() {
    check("shell", r"$ ls\r\nfile\033[?25l\033[4h\033[?7l\r\n$ ");
}
