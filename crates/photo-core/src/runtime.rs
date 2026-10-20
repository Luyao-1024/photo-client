use photo_domain::profile::ValidatedProfile;
use std::sync::Mutex;
use thiserror::Error;
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapSnapshot {
    pub profile_id: String,
    pub profile_digest: String,
    pub bridge_protocol_version: u32,
    pub session_id: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeEvent {
    pub sequence: u64,
    pub status: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum RuntimeError {
    #[error("AlreadyInitialized: the native bootstrap is already active")]
    AlreadyInitialized,
    #[error("NotInitialized: the native bootstrap is closed")]
    NotInitialized,
    #[error("Internal: runtime state is unavailable")]
    Internal,
    #[error("InputTooLarge: round-trip input exceeds the bootstrap limit")]
    InputTooLarge,
}

struct State {
    active: Option<BootstrapSnapshot>,
    sequence: u64,
}

pub struct BootstrapRuntime {
    state: Mutex<State>,
    events: broadcast::Sender<RuntimeEvent>,
}

impl Default for BootstrapRuntime {
    fn default() -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            state: Mutex::new(State {
                active: None,
                sequence: 0,
            }),
            events,
        }
    }
}

impl BootstrapRuntime {
    pub fn initialize(&self, profile: ValidatedProfile) -> Result<BootstrapSnapshot, RuntimeError> {
        let mut state = self.state.lock().map_err(|_| RuntimeError::Internal)?;
        if state.active.is_some() {
            return Err(RuntimeError::AlreadyInitialized);
        }
        let snapshot = BootstrapSnapshot {
            profile_id: profile.profile().profile_id.clone(),
            profile_digest: profile.digest().into(),
            bridge_protocol_version: photo_domain::BRIDGE_PROTOCOL_VERSION,
            session_id: Uuid::new_v4().to_string(),
            status: "bridge_ready".into(),
        };
        state.active = Some(snapshot.clone());
        Self::emit(&mut state, &self.events, "bridge_ready")?;
        Ok(snapshot)
    }

    pub fn round_trip(&self, message: String) -> Result<String, RuntimeError> {
        if message.len() > 4_096 {
            return Err(RuntimeError::InputTooLarge);
        }
        let mut state = self.state.lock().map_err(|_| RuntimeError::Internal)?;
        if state.active.is_none() {
            return Err(RuntimeError::NotInitialized);
        }
        Self::emit(&mut state, &self.events, "round_trip_complete")?;
        Ok(message)
    }

    pub fn notify(&self, status: &str) -> Result<(), RuntimeError> {
        let mut state = self.state.lock().map_err(|_| RuntimeError::Internal)?;
        if state.active.is_none() {
            return Err(RuntimeError::NotInitialized);
        }
        Self::emit(&mut state, &self.events, status)
    }

    /// The lock registers the receiver and captures the initial event atomically.
    pub fn subscribe(
        &self,
    ) -> Result<(RuntimeEvent, broadcast::Receiver<RuntimeEvent>), RuntimeError> {
        let state = self.state.lock().map_err(|_| RuntimeError::Internal)?;
        let snapshot = state.active.as_ref().ok_or(RuntimeError::NotInitialized)?;
        let receiver = self.events.subscribe();
        Ok((
            RuntimeEvent {
                sequence: state.sequence,
                status: snapshot.status.clone(),
            },
            receiver,
        ))
    }

    pub fn shutdown(&self) -> Result<(), RuntimeError> {
        let mut state = self.state.lock().map_err(|_| RuntimeError::Internal)?;
        if state.active.take().is_some() {
            Self::emit(&mut state, &self.events, "closed")?;
        }
        Ok(())
    }

    fn emit(
        state: &mut State,
        sender: &broadcast::Sender<RuntimeEvent>,
        status: &str,
    ) -> Result<(), RuntimeError> {
        state.sequence = state
            .sequence
            .checked_add(1)
            .ok_or(RuntimeError::Internal)?;
        let _ = sender.send(RuntimeEvent {
            sequence: state.sequence,
            status: status.into(),
        });
        Ok(())
    }
}
