//! A terminal grid per tile: an alacritty `Term` fed raw pane bytes, read back
//! as styled runs per line for a renderer.

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{self, Color, Processor, StdSyncHandler};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

/// Cells of one style, starting at column `col`. A wide character is a run of
/// its own, so a renderer can place every run on the cell grid.
#[derive(Clone, Debug, PartialEq)]
pub struct Run {
    pub col: usize,
    pub text: String,
    pub fg: Rgb,
    pub bg: Rgb,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

/// What the screen shows right now.
#[derive(Debug)]
pub struct Screen {
    pub lines: Vec<Vec<Run>>,
    pub cols: usize,
    pub rows: usize,
}

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

pub use alacritty_terminal::term::TermMode as Mode;

/// What `display-message -p` prints for a seed, just before its `capture-pane`.
/// Bracketed paste and focus reporting have no tmux format and need none:
/// paste goes through `paste-buffer -p`, focus through `select-pane`.
pub const SEED_FORMAT: &str = "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{alternate_on} \
#{cursor_flag} #{insert_flag} #{keypad_cursor_flag} #{keypad_flag} #{mouse_standard_flag} \
#{mouse_button_flag} #{mouse_all_flag} #{mouse_sgr_flag} #{wrap_flag} #{cursor_shape} #{cursor_blinking}";

/// A pane's size, cursor and terminal modes, as tmux reports them.
#[derive(Debug, PartialEq)]
pub struct PaneState {
    pub cols: usize,
    pub rows: usize,
    pub cursor: (usize, usize),
    pub alt: bool,
    pub show_cursor: bool,
    pub insert: bool,
    pub app_cursor: bool,
    pub app_keypad: bool,
    /// 1000, 1002 or 1003.
    pub mouse: Option<u16>,
    pub sgr_mouse: bool,
    pub wrap: bool,
    /// DECSCUSR: 0 default, 1/2 block, 3/4 underline, 5/6 bar (odd blinks).
    pub cursor_style: u8,
}

impl PaneState {
    /// Parse one [`SEED_FORMAT`] line.
    pub fn parse(line: &[u8]) -> Option<PaneState> {
        let line = String::from_utf8_lossy(line);
        let f: Vec<&str> = line.split(' ').collect();
        let [
            w,
            h,
            x,
            y,
            alt,
            cur,
            ins,
            kcur,
            kpad,
            m1000,
            m1002,
            m1003,
            sgr,
            wrap,
            shape,
            blink,
        ] = f[..]
        else {
            return None;
        };
        let on = |s: &str| s == "1";
        let base = match shape {
            "block" => 1,
            "underline" => 3,
            "bar" => 5,
            _ => 0,
        };
        Some(PaneState {
            cols: w.parse().ok()?,
            rows: h.parse().ok()?,
            cursor: (x.parse().ok()?, y.parse().ok()?),
            alt: on(alt),
            show_cursor: on(cur),
            insert: on(ins),
            app_cursor: on(kcur),
            app_keypad: on(kpad),
            mouse: [(m1003, 1003), (m1002, 1002), (m1000, 1000)]
                .iter()
                .find(|(f, _)| on(f))
                .map(|&(_, m)| m),
            sgr_mouse: on(sgr),
            wrap: on(wrap),
            cursor_style: if base > 0 && !on(blink) {
                base + 1
            } else {
                base
            },
        })
    }
}

pub const FG: Rgb = Rgb(0xe0, 0xde, 0xf4);
pub const BG: Rgb = Rgb(0x23, 0x21, 0x36);

pub struct Tile {
    term: Term<VoidListener>,
    parser: Processor<StdSyncHandler>,
}

impl Tile {
    pub fn new(cols: usize, rows: usize) -> Self {
        let term = Term::new(Config::default(), &Size { cols, rows }, VoidListener);
        Tile {
            term,
            parser: Processor::new(),
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.term.resize(Size { cols, rows });
    }

    /// Rebuild the pane from `capture-pane -p -e` lines and its [`PaneState`]:
    /// size, screen, cursor, and the modes a real attach would have replayed, so
    /// later output and input encoding behave as if the `Term` saw it all.
    pub fn seed(&mut self, st: &PaneState, lines: &[Vec<u8>]) {
        self.resize(st.cols, st.rows);
        let mut b = b"\x1bc".to_vec();
        if st.alt {
            b.extend_from_slice(b"\x1b[?1049h");
        }
        for (i, l) in lines.iter().enumerate() {
            if i > 0 {
                b.extend_from_slice(b"\r\n");
            }
            b.extend_from_slice(l);
            b.extend_from_slice(b"\x1b[0m");
        }
        b.extend_from_slice(format!("\x1b[{};{}H", st.cursor.1 + 1, st.cursor.0 + 1).as_bytes());
        for (on, seq) in [
            (!st.show_cursor, &b"\x1b[?25l"[..]),
            (st.insert, b"\x1b[4h"),
            (st.app_cursor, b"\x1b[?1h"),
            (st.app_keypad, b"\x1b="),
            (st.sgr_mouse, b"\x1b[?1006h"),
            (!st.wrap, b"\x1b[?7l"),
        ] {
            if on {
                b.extend_from_slice(seq);
            }
        }
        if let Some(m) = st.mouse {
            b.extend_from_slice(format!("\x1b[?{m}h").as_bytes());
        }
        if st.cursor_style > 0 {
            b.extend_from_slice(format!("\x1b[{} q", st.cursor_style).as_bytes());
        }
        self.feed(&b);
    }

    pub fn mode(&self) -> TermMode {
        *self.term.mode()
    }

    /// `(column, line)` of the cursor.
    pub fn cursor(&self) -> (usize, usize) {
        let p = self.term.grid().cursor.point;
        (p.column.0, p.line.0.max(0) as usize)
    }

    pub fn screen(&self) -> Screen {
        let content = self.term.renderable_content();
        let (cols, rows) = (self.term.columns(), self.term.screen_lines());
        let show_cursor = content.mode.contains(TermMode::SHOW_CURSOR);
        let cursor = content.cursor.point;
        let mut lines: Vec<Vec<Run>> = (0..rows).map(|_| Vec::new()).collect();
        let mut prev_wide = false;
        for cell in content.display_iter {
            let y = cell.point.line.0 + content.display_offset as i32;
            if y < 0 || y as usize >= rows || cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                continue;
            }
            let mut fg = color(content.colors, cell.fg, FG);
            let mut bg = color(content.colors, cell.bg, BG);
            if cell.flags.contains(Flags::INVERSE) ^ (show_cursor && cell.point == cursor) {
                std::mem::swap(&mut fg, &mut bg);
            }
            let wide = cell.flags.contains(Flags::WIDE_CHAR);
            let run = Run {
                col: cell.point.column.0,
                text: if cell.flags.contains(Flags::HIDDEN) {
                    " ".into()
                } else {
                    cell.c.to_string()
                },
                fg,
                bg,
                bold: cell.flags.contains(Flags::BOLD),
                italic: cell.flags.contains(Flags::ITALIC),
                underline: cell.flags.intersects(Flags::ALL_UNDERLINES),
            };
            let line = &mut lines[y as usize];
            match line.last_mut() {
                Some(last) if !wide && !prev_wide && same_style(last, &run) => {
                    last.text.push_str(&run.text)
                }
                _ => line.push(run),
            }
            prev_wide = wide;
        }
        Screen { lines, cols, rows }
    }
}

fn same_style(a: &Run, b: &Run) -> bool {
    (a.fg, a.bg, a.bold, a.italic, a.underline) == (b.fg, b.bg, b.bold, b.italic, b.underline)
}

fn color(colors: &alacritty_terminal::term::color::Colors, c: Color, default: Rgb) -> Rgb {
    let idx = match c {
        Color::Spec(ansi::Rgb { r, g, b }) => return Rgb(r, g, b),
        Color::Indexed(i) => i as usize,
        Color::Named(n) => n as usize,
    };
    if let Some(ansi::Rgb { r, g, b }) = colors[idx] {
        return Rgb(r, g, b);
    }
    match idx {
        0..16 => ANSI[idx],
        16..232 => {
            let i = idx - 16;
            let v = |n: usize| if n == 0 { 0 } else { (n * 40 + 55) as u8 };
            Rgb(v(i / 36), v(i / 6 % 6), v(i % 6))
        }
        232..256 => {
            let v = (8 + (idx - 232) * 10) as u8;
            Rgb(v, v, v)
        }
        _ => default,
    }
}

// ponytail: xterm's 16 colours until the fleet theme's ANSI palette is exported.
const ANSI: [Rgb; 16] = [
    Rgb(0x00, 0x00, 0x00),
    Rgb(0xcd, 0x00, 0x00),
    Rgb(0x00, 0xcd, 0x00),
    Rgb(0xcd, 0xcd, 0x00),
    Rgb(0x00, 0x00, 0xee),
    Rgb(0xcd, 0x00, 0xcd),
    Rgb(0x00, 0xcd, 0xcd),
    Rgb(0xe5, 0xe5, 0xe5),
    Rgb(0x7f, 0x7f, 0x7f),
    Rgb(0xff, 0x00, 0x00),
    Rgb(0x00, 0xff, 0x00),
    Rgb(0xff, 0xff, 0x00),
    Rgb(0x5c, 0x5c, 0xff),
    Rgb(0xff, 0x00, 0xff),
    Rgb(0x00, 0xff, 0xff),
    Rgb(0xff, 0xff, 0xff),
];

#[cfg(test)]
mod tests {
    use super::*;

    fn text(s: &Screen, y: usize) -> String {
        s.lines[y]
            .iter()
            .map(|r| r.text.as_str())
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    #[test]
    fn feeds_text_and_colours() {
        let mut t = Tile::new(20, 3);
        t.feed(b"hello\r\n\x1b[31mred\x1b[0m plain\x1b[?25l");
        let s = t.screen();
        assert_eq!(
            (text(&s, 0).as_str(), text(&s, 1).as_str()),
            ("hello", "red plain")
        );
        assert_eq!(
            s.lines[1][0],
            Run {
                col: 0,
                text: "red".into(),
                fg: ANSI[1],
                bg: BG,
                bold: false,
                italic: false,
                underline: false
            }
        );
        assert_eq!((s.lines[1][1].col, s.lines[1][1].fg), (3, FG));
    }

    #[test]
    fn truecolor_256_and_cursor() {
        let mut t = Tile::new(10, 2);
        t.feed(b"\x1b[38;2;1;2;3mA\x1b[38;5;196mB\x1b[0m");
        let s = t.screen();
        assert_eq!(s.lines[0][0].fg, Rgb(1, 2, 3));
        assert_eq!(s.lines[0][1].fg, Rgb(255, 0, 0));
        // The cursor sits after "AB" and shows as an inverted cell.
        assert_eq!((s.lines[0][2].fg, s.lines[0][2].bg), (BG, FG));
    }

    #[test]
    fn seed_replays_a_capture() {
        let mut t = Tile::new(10, 3);
        t.feed(b"stale junk\x1b[?1000h");
        let st = PaneState::parse(b"10 3 3 1 0 1 0 0 0 0 0 0 0 1 default 0").unwrap();
        t.seed(&st, &[b"\x1b[1mone".to_vec(), b"two".to_vec()]);
        t.feed(b"!");
        assert!(
            !t.mode().intersects(Mode::MOUSE_MODE),
            "seeding resets modes the pane does not have"
        );
        let s = t.screen();
        assert_eq!(
            (text(&s, 0).as_str(), text(&s, 1).as_str()),
            ("one", "two!")
        );
        assert!(s.lines[0][0].bold);
        assert!(!s.lines[1][0].bold);
    }

    #[test]
    fn parses_pane_state() {
        let st = PaneState::parse(b"100 30 4 7 1 1 0 1 1 0 1 1 1 1 bar 0").unwrap();
        assert_eq!(
            st,
            PaneState {
                cols: 100,
                rows: 30,
                cursor: (4, 7),
                alt: true,
                show_cursor: true,
                insert: false,
                app_cursor: true,
                app_keypad: true,
                mouse: Some(1003),
                sgr_mouse: true,
                wrap: true,
                cursor_style: 6,
            }
        );
        assert_eq!(PaneState::parse(b"100 30"), None);
    }

    #[test]
    fn wide_chars_are_runs_of_their_own_on_the_grid() {
        let mut t = Tile::new(8, 1);
        t.feed("日本ab".as_bytes());
        let s = t.screen();
        assert_eq!(text(&s, 0), "日本ab");
        let cols: Vec<_> = s.lines[0]
            .iter()
            .map(|r| (r.col, r.text.as_str()))
            .collect();
        assert_eq!(&cols[..3], &[(0, "日"), (2, "本"), (4, "ab")]);
    }
}
