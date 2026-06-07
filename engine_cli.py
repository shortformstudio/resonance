import sys
import json
import os
import traceback
import shutil

# Add current directory to path for imports
APP_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(APP_DIR)

try:
    from analysis.engine import AudioAnalysisEngine
    from mastering.executor import MasteringExecutor
except ImportError as e:
    print(json.dumps({"error": f"Internal module import failed: {str(e)}"}))
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command provided. Use 'analyze' or 'master'."}))
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
            # master <input_path> <output_path> <metrics_json>
            if len(sys.argv) < 5:
                print(json.dumps({"error": "Insufficient arguments for mastering."}))
                sys.exit(1)
            
            input_path = sys.argv[2]
            output_path = sys.argv[3]
            metrics = json.loads(sys.argv[4])
            
            # Unified Hybrid Mastering Engine
            executor = MasteringExecutor()
            executor.apply_compensation(input_path, output_path, metrics)
            
            # --- Workflow Enhancement: Duplicated Original for Comparison ---
            output_dir = os.path.dirname(output_path)
            orig_ext = os.path.splitext(input_path)[1]
            orig_copy_name = f"ORIGINAL_REFERENCE{orig_ext}"
            orig_copy_path = os.path.join(output_dir, orig_copy_name)
            
            try:
                shutil.copy2(input_path, orig_copy_path)
            except Exception as e:
                print(json.dumps({"warning": f"Failed to copy original: {str(e)}"}))
            
            print(json.dumps({
                "success": True, 
                "output_path": output_path, 
                "comparison_path": orig_copy_path
            }))

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
