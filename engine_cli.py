import sys
import json
import os
import tempfile
import traceback
import shutil

# Add current directory to path for imports
APP_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(APP_DIR)

try:
    from analysis.engine import AudioAnalysisEngine
    from mastering.executor import MasteringExecutor
    from mastering.ab_sampler import ABSampler
except ImportError as e:
    print(json.dumps({"error": f"Internal module import failed: {str(e)}"}))
    sys.exit(1)

# All resonance exports live here (overridable via RESONANCE_EXPORT_DIR).
EXPORT_DIR = os.environ.get("RESONANCE_EXPORT_DIR", "/Users/stevenjackson/Documents/Sound")
AB_DIR = os.path.join(EXPORT_DIR, "AB sampling")

# 10-second audition previews (middle slice, every engine).
PREVIEW_DIR = os.path.join(tempfile.gettempdir(), "resonance-previews")

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command provided. Use 'analyze', 'master' or 'preview'."}))
        sys.exit(1)

    command = sys.argv[1]

    try:
        if command == "analyze":
            if len(sys.argv) < 3:
                print(json.dumps({"error": "No file path provided for analysis."}))
                sys.exit(1)
            file_path = sys.argv[2]
            engine = AudioAnalysisEngine(file_path)
            report = engine.run_full_analysis()
            print(json.dumps(report))

        elif command == "master":
            # master <input_path> <output_path> <metrics_json> [mode]
            if len(sys.argv) < 5:
                print(json.dumps({"error": "Insufficient arguments for mastering."}))
                sys.exit(1)

            input_path = sys.argv[2]
            requested_output = sys.argv[3]
            metrics = json.loads(sys.argv[4])
            mode = sys.argv[5] if len(sys.argv) > 5 else "resonance_v2"

            # Force all exports into the central Sound folder, regardless of
            # where the source track lives.
            os.makedirs(EXPORT_DIR, exist_ok=True)
            output_path = os.path.join(EXPORT_DIR, os.path.basename(requested_output))

            # Unified Hybrid Mastering Engine (mode-aware).
            executor = MasteringExecutor(mode=mode)
            executor.apply_compensation(input_path, output_path, metrics)

            # --- Original reference alongside the master (unique per track) ---
            base_stem = os.path.splitext(os.path.basename(input_path))[0]
            orig_ext = os.path.splitext(input_path)[1]
            orig_copy_path = os.path.join(EXPORT_DIR, f"ORIGINAL_REFERENCE_{base_stem}{orig_ext}")

            warning_msg = None
            try:
                shutil.copy2(input_path, orig_copy_path)
            except Exception as e:
                warning_msg = f"Failed to copy original: {str(e)}"

            # --- Before/After A/B comparison clip (30s, 5s alternating) ---
            ab_result = None
            ab_warning = None
            try:
                os.makedirs(AB_DIR, exist_ok=True)
                ab_path = os.path.join(AB_DIR, f"AB_{base_stem}.wav")
                ab_result = ABSampler(segment_seconds=5, total_seconds=30).build(
                    before_path=input_path,
                    after_path=output_path,
                    output_path=ab_path,
                )
            except Exception as e:
                ab_warning = f"A/B sample generation failed: {str(e)}"

            result = {
                "success": True,
                "output_path": output_path,
                "comparison_path": orig_copy_path,
            }
            if ab_result:
                result["ab_sample_path"] = ab_result["output_path"]
                result["ab_sample"] = ab_result
            if warning_msg:
                result["warning"] = warning_msg
            if ab_warning:
                result["ab_warning"] = ab_warning
            print(json.dumps(result))

        elif command == "preview":
            # preview <input_path> <metrics_json> — middle 10s in every engine.
            if len(sys.argv) < 4:
                print(json.dumps({"error": "Insufficient arguments for preview."}))
                sys.exit(1)
            import soundfile as sf
            import numpy as np

            input_path = sys.argv[2]
            metrics = json.loads(sys.argv[3])

            engine = AudioAnalysisEngine(input_path)
            data, rate = engine.data, engine.rate
            total = data.shape[0]
            want = min(total, int(10 * rate))
            start = max(0, (total - want) // 2)
            sl = data[start:start + want]

            os.makedirs(PREVIEW_DIR, exist_ok=True)
            stem = os.path.splitext(os.path.basename(input_path))[0]
            slice_path = os.path.join(PREVIEW_DIR, f"{stem}-slice.wav")
            sf.write(slice_path, sl, rate, subtype="PCM_16")

            previews = {}
            for m in ("resonance_v2", "clear", "unified_hybrid_v1", "club", "ivory", "vox"):
                out = os.path.join(PREVIEW_DIR, f"{stem}-preview-{m}.wav")
                MasteringExecutor(mode=m).apply_compensation(slice_path, out, metrics)
                previews[m] = out
            try:
                os.remove(slice_path)
            except OSError:
                pass
            print(json.dumps({"previews": previews}))

        else:
            print(json.dumps({"error": f"Unknown command: {command}"}))
            sys.exit(1)

    except Exception as e:
        print(json.dumps({
            "error": str(e),
            "traceback": traceback.format_exc()
        }))
        sys.exit(1)

if __name__ == "__main__":
    main()
