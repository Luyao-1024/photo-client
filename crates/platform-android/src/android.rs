//! JNI calls into `AndroidMediaBridge`. The Java side owns the platform
//! decoders; Rust owns every decision about what to scan, store and show.

use super::{ImageProbe, VideoProbe};
use jni::{
    JNIEnv, JavaVM,
    objects::{GlobalRef, JClass, JLongArray, JObject, JObjectArray, JString, JValue},
    sys,
};
use std::{
    ffi::c_void,
    path::{Path, PathBuf},
    sync::OnceLock,
};

static VM: OnceLock<JavaVM> = OnceLock::new();
static BRIDGE: OnceLock<GlobalRef> = OnceLock::new();

/// Resolves the bridge class before any Rust worker thread calls into Java.
/// Worker threads are attached natively and cannot use FindClass themselves.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_photoviewer_photo_1client_AndroidMediaBridge_nativeBind(
    mut env: JNIEnv<'_>,
    instance: JObject<'_>,
) {
    let _ = bind(&mut env, instance);
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
}

fn bind(env: &mut JNIEnv<'_>, instance: JObject<'_>) -> Result<(), jni::errors::Error> {
    let vm = env.get_java_vm()?;
    let class = env.get_object_class(&instance)?;
    let global = env.new_global_ref(class)?;
    let _ = VM.set(vm);
    let _ = BRIDGE.set(global);
    Ok(())
}

#[unsafe(no_mangle)]
pub extern "system" fn JNI_OnLoad(vm: *mut sys::JavaVM, _reserved: *mut c_void) -> sys::jint {
    if vm.is_null() {
        return sys::JNI_ERR;
    }
    // SAFETY: the runtime passes a live JavaVM for the whole process.
    match unsafe { JavaVM::from_raw(vm) } {
        Ok(vm) => {
            let _ = VM.set(vm);
            sys::JNI_VERSION_1_6
        }
        Err(_) => sys::JNI_ERR,
    }
}

/// Keeps the JNI entry points in the final shared library even though Rust
/// code never calls them directly; Kotlin resolves them by name.
pub fn retain_jni_entrypoints() -> [usize; 2] {
    [
        JNI_OnLoad as *const () as usize,
        Java_com_photoviewer_photo_1client_AndroidMediaBridge_nativeBind as *const () as usize,
    ]
}

macro_rules! with_bridge {
    (|$env:ident, $class:ident| $body:block) => {{
        let vm = VM.get().ok_or_else(|| "JniUnavailable".to_string())?;
        let bridge = BRIDGE.get().ok_or_else(|| "JniUnavailable".to_string())?;
        let mut guard = vm
            .attach_current_thread()
            .map_err(|_| "JniUnavailable".to_string())?;
        let $env = &mut *guard;
        let local = $env
            .new_local_ref(bridge.as_obj())
            .map_err(|_| "JniUnavailable".to_string())?;
        let $class = JClass::from(local);
        let result: Result<_, String> = (|| $body)();
        if $env.exception_check().unwrap_or(false) {
            let _ = $env.exception_clear();
        }
        result
    }};
}

fn string_arg<'local>(
    env: &mut JNIEnv<'local>,
    text: &str,
) -> Result<JObject<'local>, String> {
    env.new_string(text)
        .map(JObject::from)
        .map_err(|_| "JniUnavailable".to_string())
}

pub fn probe_video(path: &Path) -> Result<VideoProbe, String> {
    let path = super::utf8(path)?;
    with_bridge!(|env, class| {
        let path = string_arg(env, path)?;
        let value = env
            .call_static_method(
                class,
                "probeVideo",
                "(Ljava/lang/String;)[J",
                &[JValue::Object(&path)],
            )
            .map_err(|_| "VideoMetadataFailed".to_string())?;
        let object = value
            .l()
            .map_err(|_| "VideoMetadataFailed".to_string())?;
        if object.is_null() {
            return Err("VideoMetadataFailed".into());
        }
        let array = JLongArray::from(object);
        let length = env
            .get_array_length(&array)
            .map_err(|_| "VideoMetadataFailed".to_string())?;
        if length < 5 {
            return Err("VideoMetadataFailed".into());
        }
        let mut values = vec![0i64; length as usize];
        env.get_long_array_region(&array, 0, &mut values)
            .map_err(|_| "VideoMetadataFailed".to_string())?;
        let width = u32::try_from(values[0]).map_err(|_| "VideoMetadataFailed".to_string())?;
        let height = u32::try_from(values[1]).map_err(|_| "VideoMetadataFailed".to_string())?;
        if width == 0 || height == 0 {
            return Err("VideoMetadataFailed".into());
        }
        Ok(VideoProbe {
            width,
            height,
            duration_ms: values[2].max(0),
            rotation: values[3].clamp(0, 359) as u32,
            capture_time_ms: (values[4] > 0).then_some(values[4]),
        })
    })
}

pub fn video_thumbnail(path: &Path, destination: &Path, max_edge: u32) -> Result<(), String> {
    thumbnail(path, destination, max_edge, "videoThumbnail", "VideoThumbnailFailed")
}

pub fn probe_image(path: &Path) -> Result<ImageProbe, String> {
    let path = super::utf8(path)?;
    with_bridge!(|env, class| {
        let path = string_arg(env, path)?;
        let value = env
            .call_static_method(
                class,
                "probeImage",
                "(Ljava/lang/String;)[J",
                &[JValue::Object(&path)],
            )
            .map_err(|_| "HeifReadFailed".to_string())?;
        let object = value.l().map_err(|_| "HeifReadFailed".to_string())?;
        if object.is_null() {
            return Err("HeifReadFailed".into());
        }
        let array = JLongArray::from(object);
        let length = env
            .get_array_length(&array)
            .map_err(|_| "HeifReadFailed".to_string())?;
        if length < 4 {
            return Err("HeifReadFailed".into());
        }
        let mut values = vec![0i64; length as usize];
        env.get_long_array_region(&array, 0, &mut values)
            .map_err(|_| "HeifReadFailed".to_string())?;
        let width = u32::try_from(values[0]).map_err(|_| "HeifReadFailed".to_string())?;
        let height = u32::try_from(values[1]).map_err(|_| "HeifReadFailed".to_string())?;
        if width == 0 || height == 0 {
            return Err("HeifReadFailed".into());
        }
        Ok(ImageProbe {
            width,
            height,
            orientation: if (1..=8).contains(&values[2]) {
                values[2] as u8
            } else {
                1
            },
            capture_time_ms: (values[3] > 0).then_some(values[3]),
        })
    })
}

pub fn image_thumbnail(path: &Path, destination: &Path, max_edge: u32) -> Result<(), String> {
    thumbnail(path, destination, max_edge, "imageThumbnail", "EncodeFailed")
}

fn thumbnail(
    path: &Path,
    destination: &Path,
    max_edge: u32,
    method: &str,
    failure: &str,
) -> Result<(), String> {
    let path = super::utf8(path)?;
    let destination = super::utf8(destination)?;
    let edge = i32::try_from(max_edge).map_err(|_| "InvalidImageHeader".to_string())?;
    with_bridge!(|env, class| {
        let path = string_arg(env, path)?;
        let destination = string_arg(env, destination)?;
        let value = env
            .call_static_method(
                class,
                method,
                "(Ljava/lang/String;Ljava/lang/String;I)Z",
                &[
                    JValue::Object(&path),
                    JValue::Object(&destination),
                    JValue::Int(edge),
                ],
            )
            .map_err(|_| failure.to_string())?;
        if value.z().unwrap_or(false) {
            Ok(())
        } else {
            Err(failure.into())
        }
    })
}

pub fn media_directories() -> Vec<PathBuf> {
    directories().unwrap_or_default()
}

fn directories() -> Result<Vec<PathBuf>, String> {
    with_bridge!(|env, class| {
        let value = env
            .call_static_method(
                class,
                "mediaDirectories",
                "()[Ljava/lang/String;",
                &[],
            )
            .map_err(|_| "JniUnavailable".to_string())?;
        let object = value.l().map_err(|_| "JniUnavailable".to_string())?;
        if object.is_null() {
            return Ok(Vec::new());
        }
        let array = JObjectArray::from(object);
        let length = env
            .get_array_length(&array)
            .map_err(|_| "JniUnavailable".to_string())?;
        let mut paths = Vec::new();
        for index in 0..length {
            let element = env
                .get_object_array_element(&array, index)
                .map_err(|_| "JniUnavailable".to_string())?;
            if element.is_null() {
                continue;
            }
            let text: String = env
                .get_string(&JString::from(element))
                .map_err(|_| "JniUnavailable".to_string())?
                .into();
            let path = PathBuf::from(text);
            if path.is_absolute() && path.is_dir() {
                paths.push(path);
            }
        }
        Ok(paths)
    })
}
