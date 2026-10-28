#!/bin/sh
# Generates the legal, original test media used by the offline player test (no third-party content):
#  - aether_test.mp4        : 8 s, 640x360 H.264 + AAC (generated test pattern and a sine tone)
#  - aether_multitrack.mkv  : same picture, two audio tracks (ita 440 Hz / eng 880 Hz) and two soft subtitle tracks (SRT)
set -e
OUT="$(dirname "$0")/../assets/test"
mkdir -p "$OUT"
cat > "$OUT/aether_test_ita.srt" <<'SRT'
1
00:00:00,500 --> 00:00:03,000
Sottotitolo di prova (italiano)

2
00:00:03,500 --> 00:00:07,500
Aether: player di prova offline
SRT
cat > "$OUT/aether_test_eng.srt" <<'SRT'
1
00:00:00,500 --> 00:00:03,000
Test subtitle (English)

2
00:00:03,500 --> 00:00:07,500
Aether: offline test player
SRT
VID="testsrc2=size=640x360:rate=24:duration=8"
ffmpeg -y -loglevel error -f lavfi -i "$VID" -f lavfi -i "sine=frequency=440:duration=8" \
  -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -c:a aac -b:a 64k -shortest -movflags +faststart "$OUT/aether_test.mp4"
ffmpeg -y -loglevel error -f lavfi -i "$VID" -f lavfi -i "sine=frequency=440:duration=8" -f lavfi -i "sine=frequency=880:duration=8" \
  -i "$OUT/aether_test_ita.srt" -i "$OUT/aether_test_eng.srt" \
  -map 0:v -map 1:a -map 2:a -map 3 -map 4 -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -c:a aac -b:a 64k -c:s srt \
  -metadata:s:a:0 language=ita -metadata:s:a:1 language=eng -metadata:s:s:0 language=ita -metadata:s:s:1 language=eng "$OUT/aether_multitrack.mkv"
