//! One sweep per burst of local changes, never an idle poll.
//!
//! Local writes that can create a cloud obligation publish a generation. The
//! scheduler waits until a generation has been quiet for `QUIET_PERIOD`, then
//! asks the cloud service to run once if durable work exists. Cloud writes do
//! not publish generations, so a sweep cannot schedule itself. With no local
//! change the task waits on the channel forever.
use photo_core::local_library::LocalLibrary;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;

const QUIET_PERIOD: Duration = Duration::from_secs(10);

fn requests() -> &'static watch::Sender<u64> {
    static REQUESTS: OnceLock<watch::Sender<u64>> = OnceLock::new();
    REQUESTS.get_or_init(|| watch::Sender::new(0))
}

/// A local library write happened. Bursts keep restarting the quiet period.
pub(super) fn note_local_change() {
    // Mutate under a single write lock. Passing sender.borrow() directly to
    // send_replace would retain its read guard while acquiring the write lock,
    // preventing the scan guard from dropping and resuming thumbnail work.
    requests().send_modify(|generation| *generation = generation.wrapping_add(1));
}

struct Running {
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
}

fn running() -> &'static Mutex<Option<Running>> {
    static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();
    RUNNING.get_or_init(|| Mutex::new(None))
}

pub(super) fn start(library: LocalLibrary) {
    let Ok(mut slot) = running().lock() else {
        return;
    };
    if slot
        .as_ref()
        .is_some_and(|running| !running.task.is_finished())
    {
        return;
    }
    let (stop, stop_rx) = watch::channel(false);
    let task = tokio::spawn(run(library, stop_rx));
    *slot = Some(Running { stop, task });
}

pub(super) fn stop() {
    let Ok(mut slot) = running().lock() else {
        return;
    };
    if let Some(running) = slot.take() {
        let _ = running.stop.send(true);
        running.task.abort();
    }
}

async fn run(library: LocalLibrary, mut stop: watch::Receiver<bool>) {
    let mut requests = requests().subscribe();
    let mut handled = 0;
    while !*stop.borrow() {
        let Some(generation) =
            next_quiet_generation(&mut requests, handled, QUIET_PERIOD, &mut stop).await
        else {
            return;
        };
        handled = generation;
        if library.is_closed() {
            return;
        }
        if let Err(error) = super::cloud_sync::run_auto_sync(library.clone()).await {
            eprintln!("cloud_auto_sync phase=error error={error}");
        }
    }
}

/// Wait for a generation newer than `handled`, then for it to stay the newest
/// for `quiet`. Returns `None` when the scheduler is asked to stop.
async fn next_quiet_generation(
    requests: &mut watch::Receiver<u64>,
    handled: u64,
    quiet: Duration,
    stop: &mut watch::Receiver<bool>,
) -> Option<u64> {
    loop {
        if *stop.borrow() {
            return None;
        }
        if *requests.borrow() == handled {
            tokio::select! {
                changed = requests.changed() => { changed.ok()?; }
                _ = stop.changed() => return None,
            }
        }
        let mut generation = *requests.borrow_and_update();
        if generation == handled {
            continue;
        }
        loop {
            tokio::select! {
                _ = tokio::time::sleep(quiet) => return Some(generation),
                changed = requests.changed() => {
                    changed.ok()?;
                    let next = *requests.borrow_and_update();
                    if next != generation {
                        generation = next;
                    }
                }
                _ = stop.changed() => return None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_change_notification_returns_and_advances_the_generation() {
        let receiver = requests().subscribe();
        let before = *receiver.borrow();
        let (done, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            note_local_change();
            done.send(()).unwrap();
        });
        received
            .recv_timeout(Duration::from_secs(1))
            .expect("local change notification must not deadlock the scan thread");
        worker.join().unwrap();
        assert_eq!(*receiver.borrow(), before.wrapping_add(1));
        assert!(receiver.has_changed().unwrap());
    }

    #[tokio::test]
    async fn an_idle_library_never_requests_a_run() {
        let (_sender, mut requests) = watch::channel(0u64);
        let (_stop_sender, mut stop) = watch::channel(false);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(80),
                next_quiet_generation(&mut requests, 0, Duration::from_millis(20), &mut stop),
            )
            .await
            .is_err()
        );
    }

    #[tokio::test]
    async fn one_change_runs_once_and_idle_time_does_not_repeat_it() {
        let (sender, mut requests) = watch::channel(0u64);
        let (_stop_sender, mut stop) = watch::channel(false);
        sender.send_replace(1);
        let generation = tokio::time::timeout(
            Duration::from_millis(200),
            next_quiet_generation(&mut requests, 0, Duration::from_millis(20), &mut stop),
        )
        .await
        .expect("a local change must trigger")
        .expect("the scheduler must still be running");
        assert_eq!(generation, 1);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(80),
                next_quiet_generation(
                    &mut requests,
                    generation,
                    Duration::from_millis(20),
                    &mut stop,
                ),
            )
            .await
            .is_err(),
            "idle time must not produce another run"
        );
    }

    #[tokio::test]
    async fn a_burst_collapses_to_one_run_at_the_latest_generation() {
        let (sender, mut requests) = watch::channel(0u64);
        let (_stop_sender, mut stop) = watch::channel(false);
        sender.send_replace(1);
        tokio::time::sleep(Duration::from_millis(5)).await;
        sender.send_replace(2);
        let generation = tokio::time::timeout(
            Duration::from_millis(200),
            next_quiet_generation(&mut requests, 0, Duration::from_millis(20), &mut stop),
        )
        .await
        .expect("the burst must trigger one run")
        .expect("the scheduler must still be running");
        assert_eq!(generation, 2);
    }

    #[tokio::test]
    async fn stopping_cancels_a_waiting_scheduler() {
        let (_sender, mut requests) = watch::channel(0u64);
        let (stop_sender, mut stop) = watch::channel(false);
        let waiting = tokio::spawn(async move {
            next_quiet_generation(&mut requests, 0, Duration::from_secs(5), &mut stop).await
        });
        stop_sender.send_replace(true);
        let result = tokio::time::timeout(Duration::from_millis(200), waiting)
            .await
            .expect("stop must wake the scheduler")
            .expect("the scheduler task must not panic");
        assert!(result.is_none());
    }
}
