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

    /// Seed from `capture-pane -p -e` lines, then put the cursor where tmux has it.
    pub fn seed(&mut self, lines: &[Vec<u8>], cursor_x: usize, cursor_y: usize) {
        self.feed(b"\x1b[H\x1b[2J\x1b[0m");
        for (i, l) in lines.iter().enumerate() {
            if i > 0 {
                self.feed(b"\r\n");
            }
            self.feed(l);
            self.feed(b"\x1b[0m");
        }
        self.feed(format!("\x1b[{};{}H", cursor_y + 1, cursor_x + 1).as_bytes());
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
        t.feed(b"stale junk");
        t.seed(&[b"\x1b[1mone".to_vec(), b"two".to_vec()], 3, 1);
        t.feed(b"!");
        let s = t.screen();
        assert_eq!(
            (text(&s, 0).as_str(), text(&s, 1).as_str()),
            ("one", "two!")
        );
        assert!(s.lines[0][0].bold);
        assert!(!s.lines[1][0].bold);
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
