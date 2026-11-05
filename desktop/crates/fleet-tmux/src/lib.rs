//! A tmux control-mode client (`tmux -L <socket> -C attach -t <session>`).
//!
//! One reader thread parses tmux's line protocol into [`Event`]s, delivered in
//! the order tmux wrote them, so a command's [`Event::Reply`] is ordered
//! against the `%output` around it: output that arrives before a
//! `capture-pane` reply is already in the capture.

use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;

#[derive(Debug, PartialEq)]
pub enum Event {
    /// `%output %<pane> <bytes>`: bytes the pane wrote, unescaped.
    Output { pane: u32, bytes: Vec<u8> },
    /// The `%begin`…`%end`/`%error` block answering the `seq`-th command.
    /// `seq` 0 is the attach itself; [`Client::send`] returns the rest.
    Reply {
        seq: u64,
        ok: bool,
        lines: Vec<Vec<u8>>,
    },
    /// `%exit [reason]`, or the stream ended.
    Exit(Option<String>),
    /// Any other notification line (`%layout-change …`, `%window-add …`).
    Notification(Vec<u8>),
}

pub struct Client {
    child: Child,
    stdin: ChildStdin,
    sent: u64,
}

impl Client {
    pub fn attach(socket: &str, session: &str) -> io::Result<(Client, mpsc::Receiver<Event>)> {
        let mut child = Command::new(std::env::var("TMUX_BIN").unwrap_or_else(|_| "tmux".into()))
            .args(["-L", socket, "-C", "attach", "-t", &format!("={session}")])
            .env_remove("TMUX")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut parser = Parser::default();
            let mut reader = BufReader::new(stdout);
            let mut line = Vec::new();
            loop {
                line.clear();
                match reader.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => {
                        let _ = tx.send(Event::Exit(None));
                        return;
                    }
                    Ok(_) => {}
                }
                if line.last() == Some(&b'\n') {
                    line.pop();
                }
                if let Some(ev) = parser.line(&line) {
                    let exit = matches!(ev, Event::Exit(_));
                    if tx.send(ev).is_err() || exit {
                        return;
                    }
                }
            }
        });
        Ok((
            Client {
                child,
                stdin,
                sent: 0,
            },
            rx,
        ))
    }

    /// Send commands as one line, so tmux runs them back to back with no pane
    /// output in between. Each gets its own [`Event::Reply`]; returns the first's `seq`.
    pub fn send(&mut self, cmds: &[&str]) -> io::Result<u64> {
        writeln!(self.stdin, "{}", cmds.join(" ; "))?;
        self.stdin.flush()?;
        let first = self.sent + 1;
        self.sent += cmds.len() as u64;
        Ok(first)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        // An empty line detaches a control client.
        let _ = self.stdin.write_all(b"\n");
        let _ = self.child.wait();
    }
}

/// The protocol state: whether we are inside a reply block.
#[derive(Default)]
pub struct Parser {
    block: Option<Vec<Vec<u8>>>,
    replies: u64,
}

impl Parser {
    pub fn line(&mut self, line: &[u8]) -> Option<Event> {
        if let Some(lines) = &mut self.block {
            let (end, err) = (line.starts_with(b"%end "), line.starts_with(b"%error "));
            if !end && !err {
                lines.push(line.to_vec());
                return None;
            }
            let lines = self.block.take().unwrap_or_default();
            let seq = self.replies;
            self.replies += 1;
            return Some(Event::Reply {
                seq,
                ok: end,
                lines,
            });
        }
        if line.starts_with(b"%begin ") {
            self.block = Some(Vec::new());
            return None;
        }
        if let Some(rest) = line.strip_prefix(b"%output %") {
            let sp = rest.iter().position(|&b| b == b' ')?;
            let pane = std::str::from_utf8(&rest[..sp]).ok()?.parse().ok()?;
            return Some(Event::Output {
                pane,
                bytes: unescape(&rest[sp + 1..]),
            });
        }
        if line == b"%exit" {
            return Some(Event::Exit(None));
        }
        if let Some(reason) = line.strip_prefix(b"%exit ") {
            return Some(Event::Exit(Some(
                String::from_utf8_lossy(reason).into_owned(),
            )));
        }
        Some(Event::Notification(line.to_vec()))
    }
}

/// Undo tmux's `%output` escaping: bytes below 0x20 and `\` arrive as `\ooo`.
pub fn unescape(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'\\'
            && i + 3 < s.len()
            && s[i + 1..i + 4].iter().all(|b| (b'0'..=b'7').contains(b))
        {
            out.push((s[i + 1] - b'0') * 64 + (s[i + 2] - b'0') * 8 + (s[i + 3] - b'0'));
            i += 4;
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

/// Quote a string as one tmux command argument.
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unescapes_octal_and_keeps_raw_utf8() {
        assert_eq!(unescape(br"a\033[1mb\134c\015\012"), b"a\x1b[1mb\\c\r\n");
        assert_eq!(unescape("é✓".as_bytes()), "é✓".as_bytes());
        assert_eq!(unescape(br"tail\03"), br"tail\03");
    }

    #[test]
    fn parses_output_replies_and_exit_in_order() {
        let mut p = Parser::default();
        let evs: Vec<_> = [
            &b"%begin 1 1 0"[..],
            b"%end 1 1 0",
            b"%output %3 hi\\015\\012",
            b"%begin 2 2 1",
            b"line one",
            b"%output %9 not output inside a block",
            b"%end 2 2 1",
            b"%begin 3 3 1",
            b"bad target",
            b"%error 3 3 1",
            b"%layout-change @1 abc",
            b"%exit detached",
        ]
        .iter()
        .filter_map(|l| p.line(l))
        .collect();
        assert_eq!(
            evs,
            vec![
                Event::Reply {
                    seq: 0,
                    ok: true,
                    lines: vec![]
                },
                Event::Output {
                    pane: 3,
                    bytes: b"hi\r\n".to_vec()
                },
                Event::Reply {
                    seq: 1,
                    ok: true,
                    lines: vec![
                        b"line one".to_vec(),
                        b"%output %9 not output inside a block".to_vec()
                    ],
                },
                Event::Reply {
                    seq: 2,
                    ok: false,
                    lines: vec![b"bad target".to_vec()]
                },
                Event::Notification(b"%layout-change @1 abc".to_vec()),
                Event::Exit(Some("detached".into())),
            ]
        );
    }

    #[test]
    fn quotes_single_quotes() {
        assert_eq!(quote("it's"), r"'it'\''s'");
    }
}
