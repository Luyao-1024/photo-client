//! Small, owned libheif boundary. Handles never cross worker threads or FFI.
use image::{DynamicImage, RgbImage};
use std::{
    ffi::{CString, c_char, c_int, c_void},
    path::Path,
    ptr,
};
#[repr(C)]
struct HeifError {
    code: c_int,
    subcode: c_int,
    message: *const c_char,
}
#[link(name = "heif")]
unsafe extern "C" {
    fn heif_context_alloc() -> *mut c_void;
    fn heif_context_free(context: *mut c_void);
    fn heif_context_read_from_file(
        context: *mut c_void,
        path: *const c_char,
        options: *const c_void,
    ) -> HeifError;
    fn heif_context_get_primary_image_handle(
        context: *mut c_void,
        handle: *mut *mut c_void,
    ) -> HeifError;
    fn heif_image_handle_release(handle: *mut c_void);
    fn heif_image_handle_get_width(handle: *const c_void) -> c_int;
    fn heif_image_handle_get_height(handle: *const c_void) -> c_int;
    fn heif_decode_image(
        handle: *const c_void,
        image: *mut *mut c_void,
        colorspace: c_int,
        chroma: c_int,
        options: *const c_void,
    ) -> HeifError;
    fn heif_image_release(image: *mut c_void);
    fn heif_image_get_width(image: *const c_void, channel: c_int) -> c_int;
    fn heif_image_get_height(image: *const c_void, channel: c_int) -> c_int;
    fn heif_image_get_plane_readonly(
        image: *const c_void,
        channel: c_int,
        stride: *mut c_int,
    ) -> *const u8;
    fn heif_image_handle_get_list_of_metadata_block_IDs(
        handle: *const c_void,
        filter: *const c_char,
        ids: *mut u32,
        count: c_int,
    ) -> c_int;
    fn heif_image_handle_get_metadata_size(handle: *const c_void, id: u32) -> usize;
    fn heif_image_handle_get_metadata(
        handle: *const c_void,
        id: u32,
        data: *mut c_void,
    ) -> HeifError;
}
struct Handle {
    context: *mut c_void,
    handle: *mut c_void,
}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            if !self.handle.is_null() {
                heif_image_handle_release(self.handle);
            }
            heif_context_free(self.context);
        }
    }
}
impl Handle {
    fn open(path: &Path) -> Result<Self, String> {
        let path = CString::new(path.to_str().ok_or("UnsupportedPathEncoding")?)
            .map_err(|_| "UnsupportedPathEncoding")?;
        // SAFETY: all pointers are library-owned, checked, and released by Drop.
        unsafe {
            let context = heif_context_alloc();
            if context.is_null() {
                return Err("DecodeBudgetExceeded".into());
            }
            let mut value = Self {
                context,
                handle: ptr::null_mut(),
            };
            if heif_context_read_from_file(context, path.as_ptr(), ptr::null()).code != 0 {
                return Err("HeifReadFailed".into());
            }
            if heif_context_get_primary_image_handle(context, &mut value.handle).code != 0
                || value.handle.is_null()
            {
                return Err("HeifReadFailed".into());
            }
            Ok(value)
        }
    }
    fn dimensions(&self) -> Result<(u32, u32), String> {
        let (w, h) = unsafe {
            (
                heif_image_handle_get_width(self.handle),
                heif_image_handle_get_height(self.handle),
            )
        };
        if w <= 0 || h <= 0 || i64::from(w) * i64::from(h) * 8 > 256 * 1024 * 1024 {
            return Err("DecodeBudgetExceeded".into());
        }
        Ok((w as u32, h as u32))
    }
    fn exif(&self) -> Option<Vec<u8>> {
        unsafe {
            let mut id = 0;
            if heif_image_handle_get_list_of_metadata_block_IDs(
                self.handle,
                c"Exif".as_ptr(),
                &mut id,
                1,
            ) != 1
            {
                return None;
            }
            let size = heif_image_handle_get_metadata_size(self.handle, id);
            if !(8..=1024 * 1024).contains(&size) {
                return None;
            }
            let mut bytes = vec![0; size];
            if heif_image_handle_get_metadata(self.handle, id, bytes.as_mut_ptr().cast()).code != 0
            {
                return None;
            }
            let offset = u32::from_be_bytes(bytes[..4].try_into().ok()?) as usize;
            bytes.get(4 + offset..).map(Vec::from)
        }
    }
}
pub(super) fn header(path: &Path) -> Result<super::headers::Header, String> {
    let handle = Handle::open(path)?;
    let (w, h) = handle.dimensions()?;
    let mut header = super::headers::header(w, h, 4, handle.exif())?;
    // libheif reports transformed dimensions and applies container transforms.
    header.orientation = 1;
    Ok(header)
}
pub(super) fn decode(path: &Path) -> Result<DynamicImage, String> {
    let handle = Handle::open(path)?;
    handle.dimensions()?;
    struct Pixels(*mut c_void);
    impl Drop for Pixels {
        fn drop(&mut self) {
            unsafe {
                heif_image_release(self.0);
            }
        }
    }
    unsafe {
        let mut image = ptr::null_mut();
        if heif_decode_image(handle.handle, &mut image, 1, 10, ptr::null()).code != 0
            || image.is_null()
        {
            return Err("HeifDecodeFailed".into());
        }
        let pixels = Pixels(image);
        let w = heif_image_get_width(pixels.0, 10);
        let h = heif_image_get_height(pixels.0, 10);
        if w <= 0 || h <= 0 || i64::from(w) * i64::from(h) * 8 > 256 * 1024 * 1024 {
            return Err("DecodeBudgetExceeded".into());
        }
        let mut stride = 0;
        let plane = heif_image_get_plane_readonly(pixels.0, 10, &mut stride);
        if plane.is_null() || stride < i32::checked_mul(w, 3).ok_or("InvalidImageHeader")? {
            return Err("HeifDecodeFailed".into());
        }
        let row_bytes = w as usize * 3;
        let mut rgb = vec![0; row_bytes * h as usize];
        for y in 0..h as usize {
            rgb[y * row_bytes..(y + 1) * row_bytes].copy_from_slice(std::slice::from_raw_parts(
                plane.add(y * stride as usize),
                row_bytes,
            ));
        }
        Ok(DynamicImage::ImageRgb8(
            RgbImage::from_raw(w as u32, h as u32, rgb).ok_or("HeifDecodeFailed")?,
        ))
    }
}

pub(super) fn exif(path: &Path) -> Option<Vec<u8>> {
    Handle::open(path).ok()?.exif()
}
