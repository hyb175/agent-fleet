//! A terminal tile: the pane's grid painted cell-exact on a canvas, at the
//! pane's own size (never sent to tmux; a terminal client keeps owning it).

use crate::session::Pane;
use crate::stats::Stats;
use gpui_kit::*;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use term::Rgb;

pub const FONT_SIZE: f32 = 13.;
pub const LINE_H: f32 = 17.;

#[cfg(target_os = "macos")]
const FONT: &str = "Menlo";
#[cfg(not(target_os = "macos"))]
const FONT: &str = "DejaVu Sans Mono";

pub struct TileView {
    pane: Arc<Mutex<Pane>>,
    family: SharedString,
    stats: Option<Rc<RefCell<Stats>>>,
}

impl TileView {
    pub fn new(
        pane: Arc<Mutex<Pane>>,
        dirty: async_channel::Receiver<()>,
        stats: Option<Rc<RefCell<Stats>>>,
        cx: &mut Context<Self>,
    ) -> Self {
        let counted = stats.clone();
        cx.spawn(async move |this, cx| {
            while dirty.recv().await.is_ok() {
                if let Some(s) = &counted {
                    s.borrow_mut().updates += 1;
                }
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        })
        .detach();
        let family = std::env::var("FLEET_DESKTOP_FONT")
            .unwrap_or_else(|_| FONT.into())
            .into();
        TileView {
            pane,
            family,
            stats,
        }
    }
}

pub fn hsla(c: Rgb) -> Hsla {
    rgb(((c.0 as u32) << 16) | ((c.1 as u32) << 8) | c.2 as u32).into()
}

struct Frame {
    quads: Vec<PaintQuad>,
    text: Vec<(Point<Pixels>, ShapedLine)>,
}

impl Render for TileView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let (pane, family, stats) = (self.pane.clone(), self.family.clone(), self.stats.clone());
        div()
            .size_full()
            .overflow_hidden()
            .bg(hsla(term::BG))
            .child(
                canvas(
                    move |bounds, window, _| layout(&pane, &family, bounds, window),
                    move |_, frame: Frame, window, cx| {
                        for q in frame.quads {
                            window.paint_quad(q);
                        }
                        for (origin, line) in frame.text {
                            let _ =
                                line.paint(origin, px(LINE_H), TextAlign::Left, None, window, cx);
                        }
                        if let Some(s) = stats {
                            s.borrow_mut().painted();
                        }
                    },
                )
                .size_full(),
            )
    }
}

fn layout(
    pane: &Mutex<Pane>,
    family: &SharedString,
    bounds: Bounds<Pixels>,
    window: &mut Window,
) -> Frame {
    let screen = pane.lock().unwrap().tile.screen();
    let ts = window.text_system();
    let base = font(family.clone());
    let size = px(FONT_SIZE);
    let cell_w = ts
        .advance(ts.resolve_font(&base), size, 'm')
        .map_or(px(8.), |s| s.width);
    let mut frame = Frame {
        quads: Vec::new(),
        text: Vec::new(),
    };
    for (y, runs) in screen.lines.iter().enumerate() {
        let top = bounds.origin.y + px(LINE_H * y as f32);
        for (i, r) in runs.iter().enumerate() {
            let x = bounds.origin.x + cell_w * r.col as f32;
            let cells = runs.get(i + 1).map_or(screen.cols, |n| n.col) - r.col;
            if r.bg != term::BG {
                frame.quads.push(fill(
                    Bounds::new(
                        point(x, top),
                        gpui_kit::size(cell_w * cells as f32, px(LINE_H)),
                    ),
                    hsla(r.bg),
                ));
            }
            if r.text.trim().is_empty() && !r.underline {
                continue;
            }
            let run = TextRun {
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
                    ..base.clone()
                },
                color: hsla(r.fg),
                background_color: None,
                underline: r.underline.then(|| UnderlineStyle {
                    thickness: px(1.),
                    color: None,
                    wavy: false,
                }),
                strikethrough: None,
            };
            frame.text.push((
                point(x, top),
                ts.shape_line(r.text.clone().into(), size, &[run], None),
            ));
        }
    }
    frame
}
