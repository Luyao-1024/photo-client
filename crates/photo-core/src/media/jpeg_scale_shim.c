// Thin C wrapper around libjpeg-turbo's libjpeg API.
// Exposes IDCT scaling (scale_num/scale_denom) via a single-shot decode
// so the whole libjpeg interaction lives under one setjmp scope (the
// custom error handler longjmps, so every entry point must guard it).
//
// The system libjpeg.so IS libjpeg-turbo on this platform; IDCT scaling
// decodes an 8000×6000 JPEG into 1000×750 RGB pixels by skipping
// high-frequency DCT coefficients, roughly 8× faster than full decode.
//
// Resource-safety: both `fp` and the decoded `buf` live in the struct so
// the longjmp error path can release them (libjpeg reads the body lazily,
// so fp must stay open until finish_decompress; a mid-decode longjmp would
// otherwise leak the FILE* and the malloc'd buffer).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <jpeglib.h>
#include <unistd.h>
#include <stdint.h>
#include <jerror.h>

struct photo_jpeg_error {
    struct jpeg_error_mgr pub;
    jmp_buf jmp;
    char message[JMSG_LENGTH_MAX];
};

struct jpeg_shim {
    struct jpeg_decompress_struct cinfo;
    struct photo_jpeg_error jerr;
    // Open source FILE*. Kept here so the error path can fclose it.
    // libjpeg reads the body lazily, so it must stay open through
    // jpeg_read_scanlines / jpeg_finish_decompress.
    FILE *fp;
    // Decoded RGB buffer. Owned by the struct (so the error path can free
    // it) until photo_jpeg_take_buffer transfers it to the caller.
    unsigned char *buf;
    // Exact malloc'd byte count of `buf` (= w * h * output_components).
    size_t buf_len;
    int buf_w;
    int buf_h;
    struct jpeg_source_mgr source;
    unsigned char input[4096];
    uint64_t remaining;
};

static void bounded_init(j_decompress_ptr cinfo) { (void)cinfo; }
static boolean bounded_fill(j_decompress_ptr cinfo) {
    struct jpeg_shim *s = (struct jpeg_shim *)cinfo->client_data;
    size_t wanted = s->remaining < sizeof(s->input) ? (size_t)s->remaining : sizeof(s->input);
    size_t count = wanted ? fread(s->input, 1, wanted, s->fp) : 0;
    if (!count) ERREXIT(cinfo, JERR_INPUT_EOF);
    s->remaining -= count;
    s->source.next_input_byte = s->input;
    s->source.bytes_in_buffer = count;
    return TRUE;
}
static void bounded_skip(j_decompress_ptr cinfo, long count) {
    if (count <= 0) return;
    while ((size_t)count > cinfo->src->bytes_in_buffer) {
        count -= (long)cinfo->src->bytes_in_buffer;
        bounded_fill(cinfo);
    }
    cinfo->src->next_input_byte += count;
    cinfo->src->bytes_in_buffer -= (size_t)count;
}
static void bounded_term(j_decompress_ptr cinfo) { (void)cinfo; }


static void shim_error_exit(j_common_ptr cinfo) {
    struct photo_jpeg_error *e = (struct photo_jpeg_error *)cinfo->err;
    (*cinfo->err->format_message)(cinfo, e->message);
    longjmp(e->jmp, 1);
}

void *photo_jpeg_create(void) {
    struct jpeg_shim *volatile s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->cinfo.err = jpeg_std_error(&s->jerr.pub);
    s->jerr.pub.error_exit = shim_error_exit;
    if (setjmp(s->jerr.jmp)) { free(s); return NULL; }
    jpeg_create_decompress(&s->cinfo);
    return s;
}

void photo_jpeg_destroy(void *ptr) {
    if (!ptr) return;
    struct jpeg_shim *s = (struct jpeg_shim *)ptr;
    jpeg_destroy_decompress(&s->cinfo);
    // If the buffer was never taken, free it here.
    if (s->buf) {
        free(s->buf);
        s->buf = NULL;
    }
    if (s->fp) {
        fclose(s->fp);
        s->fp = NULL;
    }
    free(s);
}

// Free a buffer returned by photo_jpeg_take_buffer. Callers that have
// transferred ownership out of the shim MUST free via this function (not
// via any other allocator), since the buffer was malloc'd in C.
void photo_jpeg_free_buffer(void *p) {
    free(p);
}

// Pick the largest libjpeg-turbo IDCT denominator (1, 2, 4, 8) such that
// the decoded long edge is still >= max_dim (no upsampling needed afterward).
static int pick_denom(int long_edge, int max_dim) {
    if (max_dim < 1) max_dim = 1;
    if (long_edge / 8 >= max_dim) return 8;
    if (long_edge / 4 >= max_dim) return 4;
    if (long_edge / 2 >= max_dim) return 2;
    return 1;
}

// Single-shot decode with IDCT scaling. On success returns 0, fills
// *out_w / *out_h with the SCALED (pre-orientation) dimensions, and stores
// the malloc'd RGB buffer inside the struct (fetch via photo_jpeg_take_buffer).
// On failure returns -1 and writes an error message to errmsg. The error
// path closes fp and frees any partial buffer — no resource leaks.
int photo_jpeg_decode_scaled(
    void *ptr,
    int source_fd,
    uint64_t source_size,
    int max_dim,
    int *out_w,
    int *out_h,
    char *errmsg,
    int errmsg_size
) {
    struct jpeg_shim *s = (struct jpeg_shim *)ptr;

    if (setjmp(s->jerr.jmp)) {
        // Error path: release fp + any partial buffer, report message.
        if (s->fp) { fclose(s->fp); s->fp = NULL; }
        if (s->buf) { free(s->buf); s->buf = NULL; s->buf_len = 0; }
        jpeg_abort_decompress(&s->cinfo);
        if (errmsg && errmsg_size > 0) {
            strncpy(errmsg, s->jerr.message, errmsg_size - 1);
            errmsg[errmsg_size - 1] = '\0';
        }
        return -1;
    }

    int fd = dup(source_fd);
    FILE *fp = fd < 0 ? NULL : fdopen(fd, "rb");
    if (!fp) {
        if (fd >= 0) close(fd);
        snprintf(errmsg, errmsg_size, "cannot duplicate source descriptor");
        return -1;
    }
    s->fp = fp; // hand to struct so the error path can close it
    s->remaining = source_size;
    s->source.init_source = bounded_init;
    s->source.fill_input_buffer = bounded_fill;
    s->source.skip_input_data = bounded_skip;
    s->source.resync_to_restart = jpeg_resync_to_restart;
    s->source.term_source = bounded_term;
    s->source.bytes_in_buffer = 0;
    s->source.next_input_byte = NULL;
    s->cinfo.src = &s->source;
    s->cinfo.client_data = s;
    s->cinfo.mem->max_memory_to_use = 96L * 1024L * 1024L;
    jpeg_read_header(&s->cinfo, TRUE);

    int long_edge = s->cinfo.image_width > s->cinfo.image_height
                        ? s->cinfo.image_width
                        : s->cinfo.image_height;
    int denom = pick_denom(long_edge, max_dim);
    s->cinfo.scale_num = 1;
    s->cinfo.scale_denom = denom;
    s->cinfo.out_color_space = JCS_RGB;

    jpeg_start_decompress(&s->cinfo);

    int w = s->cinfo.output_width;
    int h = s->cinfo.output_height;
    int row_stride = w * s->cinfo.output_components;
    size_t need = (size_t)row_stride * (size_t)h;
    unsigned char *buf = malloc(need);
    if (!buf) {
        // Normal (non-longjmp) failure: clean up via the struct fields.
        fclose(s->fp);
        s->fp = NULL;
        jpeg_abort_decompress(&s->cinfo);
        snprintf(errmsg, errmsg_size, "out of memory (%zu bytes)", need);
        return -1;
    }
    // Track the buffer in the struct IMMEDIATELY so a mid-scanline longjmp
    // frees it (s->buf is assigned before the loop, not after).
    s->buf = buf;
    s->buf_len = need;

    JSAMPROW rows[1];
    while (s->cinfo.output_scanline < s->cinfo.output_height) {
        rows[0] = buf + s->cinfo.output_scanline * row_stride;
        jpeg_read_scanlines(&s->cinfo, rows, 1);
    }

    jpeg_finish_decompress(&s->cinfo);
    fclose(s->fp);
    s->fp = NULL;

    s->buf_w = w;
    s->buf_h = h;
    if (out_w) *out_w = w;
    if (out_h) *out_h = h;
    return 0;
}

// Transfer ownership of the decoded buffer to the caller. Returns the
// malloc'd pointer and writes its exact byte length to *out_len. After this
// call the struct no longer owns the buffer; the caller must free it via
// photo_jpeg_free_buffer.
void *photo_jpeg_take_buffer(void *ptr, size_t *out_len) {
    struct jpeg_shim *s = (struct jpeg_shim *)ptr;
    unsigned char *buf = s->buf;
    if (out_len) *out_len = s->buf_len;
    s->buf = NULL;
    s->buf_len = 0;
    return buf;
}
