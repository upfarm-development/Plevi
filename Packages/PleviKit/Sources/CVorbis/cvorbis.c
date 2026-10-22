#include "CVorbis.h"

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

struct cvorbis_decoder {
    stb_vorbis *vorbis;
    int channels;
    unsigned int sample_rate;
};

#include <stdlib.h>

cvorbis_decoder *cvorbis_open(const char *path, int *error) {
    int code = 0;
    stb_vorbis *vorbis = stb_vorbis_open_filename(path, &code, NULL);
    if (error) *error = code;
    if (!vorbis) return NULL;
    cvorbis_decoder *decoder = (cvorbis_decoder *)calloc(1, sizeof(cvorbis_decoder));
    if (!decoder) {
        stb_vorbis_close(vorbis);
        return NULL;
    }
    stb_vorbis_info info = stb_vorbis_get_info(vorbis);
    decoder->vorbis = vorbis;
    decoder->channels = info.channels;
    decoder->sample_rate = info.sample_rate;
    return decoder;
}

int cvorbis_channels(const cvorbis_decoder *decoder) { return decoder ? decoder->channels : 0; }
unsigned int cvorbis_sample_rate(const cvorbis_decoder *decoder) { return decoder ? decoder->sample_rate : 0; }

unsigned int cvorbis_total_frames(cvorbis_decoder *decoder) {
    return decoder ? stb_vorbis_stream_length_in_samples(decoder->vorbis) : 0;
}

int cvorbis_read(cvorbis_decoder *decoder, short *interleaved, int frames) {
    if (!decoder || frames <= 0) return 0;
    return stb_vorbis_get_samples_short_interleaved(
        decoder->vorbis, decoder->channels, interleaved, frames * decoder->channels);
}

void cvorbis_close(cvorbis_decoder *decoder) {
    if (!decoder) return;
    stb_vorbis_close(decoder->vorbis);
    free(decoder);
}
