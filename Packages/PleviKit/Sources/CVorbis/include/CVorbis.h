// A thin C interface over stb_vorbis (Sean Barrett, public domain / MIT; the
// full notice is at the end of stb_vorbis.c), for the one thing the app needs
// from it: reading an Ogg Vorbis file as 16-bit interleaved PCM, which iOS's
// Core Audio will not do.
#ifndef CVORBIS_H
#define CVORBIS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cvorbis_decoder cvorbis_decoder;

/// Opens `path`. Nil on failure, with `*error` set to stb_vorbis's error code
/// when the pointer is not null.
cvorbis_decoder *cvorbis_open(const char *path, int *error);

int cvorbis_channels(const cvorbis_decoder *decoder);
unsigned int cvorbis_sample_rate(const cvorbis_decoder *decoder);

/// The length in frames, or 0 when the file does not say. Walks the file, so it
/// is called once and not in a loop.
unsigned int cvorbis_total_frames(cvorbis_decoder *decoder);

/// Decodes up to `frames` frames into `interleaved` (frames x channels
/// 16-bit samples). Returns the number of frames written; 0 at the end.
int cvorbis_read(cvorbis_decoder *decoder, short *interleaved, int frames);

void cvorbis_close(cvorbis_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
