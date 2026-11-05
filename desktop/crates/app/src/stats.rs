//! Frame timing for P3 (`FLEET_DESKTOP_STATS=<secs>`): per frame, the app's
//! CPU from the root render to the last tile painted, and the interval between
//! frames; printed as percentiles when the run ends.

use std::time::Instant;

#[derive(Default)]
pub struct Stats {
    start: Option<Instant>,
    frame_start: Option<Instant>,
    last_paint: Option<Instant>,
    cpu_ms: Vec<f64>,
    interval_ms: Vec<f64>,
    pub updates: usize,
}

impl Stats {
    /// The root view is rendering: a frame begins and the previous one is closed.
    pub fn frame(&mut self) {
        let now = Instant::now();
        self.start.get_or_insert(now);
        if let (Some(s), Some(p)) = (self.frame_start, self.last_paint) {
            if p > s {
                self.cpu_ms.push(ms(p - s));
            }
            self.interval_ms.push(ms(now - s));
        }
        self.frame_start = Some(now);
    }

    pub fn painted(&mut self) {
        self.last_paint = Some(Instant::now());
    }

    pub fn report(&mut self) -> String {
        let secs = self.start.map_or(0., |s| s.elapsed().as_secs_f64());
        let frames = self.interval_ms.len() + 1;
        format!(
            "frames {frames} in {secs:.1}s = {:.1} fps; tile updates {} = {:.0}/s\nframe cpu ms   {}\nframe interval {}",
            frames as f64 / secs,
            self.updates,
            self.updates as f64 / secs,
            pct(&mut self.cpu_ms),
            pct(&mut self.interval_ms)
        )
    }
}

fn ms(d: std::time::Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn pct(v: &mut [f64]) -> String {
    if v.is_empty() {
        return "none".into();
    }
    v.sort_by(f64::total_cmp);
    let at = |p: f64| v[((v.len() - 1) as f64 * p) as usize];
    format!(
        "p50 {:.2}  p95 {:.2}  p99 {:.2}  max {:.2}",
        at(0.5),
        at(0.95),
        at(0.99),
        v[v.len() - 1]
    )
}
