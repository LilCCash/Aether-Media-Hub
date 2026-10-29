// The FFmpeg 6.0 headers (the version inside media_kit's libmpv, which the app really runs), so the structures are read at their real
// offsets. Do not replace them with newer headers: the library is 6.0 whatever the headers say.
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/pixdesc.h>
