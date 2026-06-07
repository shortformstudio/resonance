use std::fs::File;
use std::path::Path;
use symphonia::core::audio::{AudioBufferRef, Signal};
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: symphonia-decode <input> <output_wav>");
        std::process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    let src = File::open(input_path).expect("failed to open input file");
    let mss = MediaSourceStream::new(Box::new(src), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = Path::new(input_path).extension().and_then(|s| s.to_str()) {
        hint.with_extension(ext);
    }

    let format_opts = FormatOptions::default();
    let metadata_opts = MetadataOptions::default();
    let decoder_opts = DecoderOptions::default();

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &metadata_opts)
        .expect("unsupported format");

    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .expect("no supported audio tracks");

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &decoder_opts)
        .expect("unsupported codec");

    let track_id = track.id;

    // WAV output setup
    let spec = hound::WavSpec {
        channels: track.codec_params.channels.map(|c| c.count() as u16).unwrap_or(2),
        sample_rate: track.codec_params.sample_rate.unwrap_or(44100),
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(output_path, spec).expect("failed to create wav writer");

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(Error::IoError(_)) => break,
            Err(Error::ResetRequired) => unimplemented!(),
            Err(err) => panic!("{}", err),
        };

        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                match decoded {
                    AudioBufferRef::F32(buf) => {
                        for i in 0..buf.frames() {
                            for channel in 0..buf.spec().channels.count() {
                                writer.write_sample(buf.chan(channel)[i]).unwrap();
                            }
                        }
                    }
                    AudioBufferRef::U8(buf) => {
                        for i in 0..buf.frames() {
                            for channel in 0..buf.spec().channels.count() {
                                writer.write_sample(buf.chan(channel)[i] as f32 / 128.0 - 1.0).unwrap();
                            }
                        }
                    }
                    AudioBufferRef::S16(buf) => {
                        for i in 0..buf.frames() {
                            for channel in 0..buf.spec().channels.count() {
                                writer.write_sample(buf.chan(channel)[i] as f32 / 32768.0).unwrap();
                            }
                        }
                    }
                    AudioBufferRef::S32(buf) => {
                        for i in 0..buf.frames() {
                            for channel in 0..buf.spec().channels.count() {
                                writer.write_sample(buf.chan(channel)[i] as f32 / 2147483648.0).unwrap();
                            }
                        }
                    }
                    _ => unimplemented!("unsupported audio buffer format"),
                }
            }
            Err(Error::IoError(_)) => break,
            Err(Error::DecodeError(_)) => continue,
            Err(err) => panic!("{}", err),
        }
    }
}
