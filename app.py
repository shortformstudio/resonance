import sys
import os
import json
import subprocess
import tempfile
import traceback
from datetime import datetime

print("Initializing AUDIO MASTER EVALUATOR v1.2...")

try:
    from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                                 QHBoxLayout, QPushButton, QLabel, QFrame, QFileDialog, QProgressBar, QButtonGroup, QTextEdit)
    from PyQt6.QtCore import Qt, QThread, pyqtSignal, QPropertyAnimation, QEasingCurve
    from PyQt6.QtGui import QFont, QPalette, QBrush, QPixmap, QColor
    from logging_config import get_logger
    logger = get_logger()
except ImportError as e:
    print(f"Error: Missing dependencies. {e}")
    sys.exit(1)

# Ensure internal modules are discoverable
APP_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(APP_DIR)

try:
    from analysis.engine import AudioAnalysisEngine
    from mastering.executor import MasteringExecutor
    from mastering.clear_executor import ClearExecutor
except ImportError as e:
    print(f"Error: Internal module import failed. {e}")
    sys.exit(1)

def log_error(error_msg):
    logger.error(error_msg, exc_info=True)

class AnalysisThread(QThread):
    finished = pyqtSignal(dict)
    error = pyqtSignal(str)
    status = pyqtSignal(str)

    def __init__(self, file_path):
        super().__init__()
        self.file_path = file_path

    def run(self):
        try:
            self.status.emit(f"Checking format: {os.path.basename(self.file_path)}")
            if not self.file_path.lower().endswith('.wav'):
                self.status.emit("Compressed format detected. Decoding via FFmpeg...")
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    tmp_path = tmp.name
                cmd = ["ffmpeg", "-i", self.file_path, "-y", tmp_path]
                subprocess.run(cmd, capture_output=True, check=True)
                analysis_path = tmp_path
                is_temp = True
            else:
                analysis_path = self.file_path
                is_temp = False

            self.status.emit("Loading audio into DSP engine...")
            engine = AudioAnalysisEngine(analysis_path)
            
            self.status.emit("Calculating LUFS & True Peak...")
            report = engine.run_full_analysis()
            
            report["analysis_path"] = analysis_path
            report["is_temp"] = is_temp
            self.status.emit("Analysis complete.")
            self.finished.emit(report)
        except Exception as e:
            err_trace = traceback.format_exc()
            log_error(f"Analysis Error: {str(e)}")
            self.error.emit(str(e))

class MasteringThread(QThread):
    finished = pyqtSignal(str)
    error = pyqtSignal(str)
    status = pyqtSignal(str)

    def __init__(self, input_path, metrics, output_path, mode="MASTER"):
        super().__init__()
        self.input_path = input_path
        self.metrics = metrics
        self.output_path = output_path
        self.mode = mode

    def run(self):
        try:
            self.status.emit(f"Initializing {self.mode} engine...")
            executor = ClearExecutor() if self.mode == "CLEAR" else MasteringExecutor()
            
            self.status.emit("Applying DSP compensation chain...")
            executor.apply_compensation(self.input_path, self.output_path, self.metrics)
            
            self.status.emit(f"Mastering finalized: {os.path.basename(self.output_path)}")
            self.finished.emit(self.output_path)
        except Exception as e:
            log_error(f"Mastering Error: {str(e)}")
            self.error.emit(str(e))

class MasterEvaluatorApp(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AUDIO MASTER EVALUATOR v1.2")
        self.resize(1250, 850)
        
        self.current_analysis = None
        self.current_mode = "MASTER"
        self.is_processing = False
        
        self.init_ui()
        self.apply_styles()

    def init_ui(self):
        # Background: Cream/Light
        self.setStyleSheet("background-color: #F5F5DC;") # Cream base
        
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        
        # Main Horizontal Layout: Sidebar | Content
        main_h_layout = QHBoxLayout(central_widget)
        main_h_layout.setContentsMargins(0, 0, 0, 0)
        main_h_layout.setSpacing(0)

        # --- LEFT SIDEBAR: STATUS ---
        self.sidebar = QFrame()
        self.sidebar.setFixedWidth(300)
        self.sidebar.setObjectName("sidebar")
        sidebar_layout = QVBoxLayout(self.sidebar)
        sidebar_layout.setContentsMargins(25, 40, 25, 25)
        
        sidebar_title = QLabel("SYSTEM STATUS")
        sidebar_title.setObjectName("sidebarHeader")
        sidebar_layout.addWidget(sidebar_title)
        
        self.status_log = QTextEdit()
        self.status_log.setReadOnly(True)
        self.status_log.setObjectName("statusLog")
        self.status_log.setPlaceholderText("Awaiting input...")
        sidebar_layout.addWidget(self.status_log)
        
        sidebar_layout.addStretch()
        
        app_info = QLabel("mitosisOS Engine v1.2")
        app_info.setStyleSheet("color: black; opacity: 0.5; font-size: 10px;")
        sidebar_layout.addWidget(app_info)
        
        main_h_layout.addWidget(self.sidebar)

        # --- MAIN CONTENT AREA ---
        content_container = QWidget()
        content_layout = QVBoxLayout(content_container)
        content_layout.setContentsMargins(60, 50, 60, 50)
        content_layout.setSpacing(40) # Increased Negative Space

        # HEADER
        header = QLabel("MASTER EVALUATOR")
        header.setObjectName("mainHeader")
        header.setAlignment(Qt.AlignmentFlag.AlignCenter)
        content_layout.addWidget(header)

        # MODE TOGGLE (Spaced out)
        mode_layout = QHBoxLayout()
        self.mode_group = QButtonGroup(self)
        
        self.master_mode_btn = QPushButton("MODERN MASTER")
        self.master_mode_btn.setCheckable(True)
        self.master_mode_btn.setChecked(True)
        self.master_mode_btn.setObjectName("modeButton")
        self.master_mode_btn.clicked.connect(lambda: self.set_mode("MASTER"))
        
        self.clear_mode_btn = QPushButton("ACOUSTIC CLEAR")
        self.clear_mode_btn.setCheckable(True)
        self.clear_mode_btn.setObjectName("modeButton")
        self.clear_mode_btn.clicked.connect(lambda: self.set_mode("CLEAR"))
        
        self.mode_group.addButton(self.master_mode_btn)
        self.mode_group.addButton(self.clear_mode_btn)
        
        mode_layout.addStretch()
        mode_layout.addWidget(self.master_mode_btn)
        mode_layout.addSpacing(30) # Negative Space
        mode_layout.addWidget(self.clear_mode_btn)
        mode_layout.addStretch()
        content_layout.addLayout(mode_layout)

        # SCORE PANEL (Simplified)
        self.score_panel = QFrame()
        self.score_panel.setObjectName("scorePanel")
        self.score_panel.setFixedHeight(220)
        score_layout = QVBoxLayout(self.score_panel)
        
        self.score_label = QLabel("0.0%")
        self.score_label.setObjectName("scoreText")
        self.score_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        
        self.current_status_label = QLabel("READY")
        self.current_status_label.setObjectName("statusLabel")
        self.current_status_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        
        score_layout.addWidget(self.score_label)
        score_layout.addWidget(self.current_status_label)
        content_layout.addWidget(self.score_panel)

        # METRICS GRID (Each aspect spot)
        metrics_layout = QHBoxLayout()
        metrics_layout.setSpacing(25)
        
        self.lufs_card = self.create_metric_card("LOUDNESS", "-- LUFS")
        self.slope_card = self.create_metric_card("SPECTRAL", "--")
        self.stereo_card = self.create_metric_card("WIDTH", "--")
        
        metrics_layout.addWidget(self.lufs_card)
        metrics_layout.addWidget(self.slope_card)
        metrics_layout.addWidget(self.stereo_card)
        content_layout.addLayout(metrics_layout)
        
        # PLACEHOLDER FOR FUTURE VISUALIZATION
        self.viz_spot = QFrame()
        self.viz_spot.setObjectName("vizPlaceholder")
        self.viz_spot.setFixedHeight(100)
        viz_l = QVBoxLayout(self.viz_spot)
        viz_l.addWidget(QLabel("VISUALIZATION ENGINE SPOT"), alignment=Qt.AlignmentFlag.AlignCenter)
        content_layout.addWidget(self.viz_spot)

        # ACTION BUTTONS
        btn_layout = QHBoxLayout()
        btn_layout.setSpacing(30)
        
        self.load_btn = QPushButton("SELECT AUDIO")
        self.load_btn.setObjectName("actionButton")
        self.load_btn.clicked.connect(self.select_file)
        
        self.master_btn = QPushButton("EXECUTE")
        self.master_btn.setObjectName("masterButton")
        self.master_btn.setEnabled(False)
        self.master_btn.clicked.connect(self.run_mastering)
        
        btn_layout.addStretch()
        btn_layout.addWidget(self.load_btn)
        btn_layout.addWidget(self.master_btn)
        btn_layout.addStretch()
        content_layout.addLayout(btn_layout)

        main_h_layout.addWidget(content_container, 1)

    def set_mode(self, mode):
        self.current_mode = mode
        self.update_log(f"Mode switched to: {mode}")
        if mode == "CLEAR":
            self.master_btn.setStyleSheet("background-color: #3498db; color: white;")
        else:
            self.master_btn.setStyleSheet("background-color: #000; color: white;")

    def create_metric_card(self, title, value):
        card = QFrame()
        card.setObjectName("metricCard")
        l = QVBoxLayout(card)
        t = QLabel(title); t.setObjectName("cardTitle"); t.setAlignment(Qt.AlignmentFlag.AlignCenter)
        v = QLabel(value); v.setObjectName("cardValue"); v.setAlignment(Qt.AlignmentFlag.AlignCenter)
        l.addWidget(t); l.addWidget(v)
        card.value_label = v
        return card

    def apply_styles(self):
        self.setStyleSheet("""
            QMainWindow { background-color: #0A0E17; }
            
            #sidebar { 
                background-color: rgba(255, 255, 255, 0.03); 
                border-right: 1px solid rgba(255, 255, 255, 0.1); 
            }
            #sidebarHeader { 
                color: #D4AF37; 
                font-family: 'Avenir'; 
                font-weight: 800; 
                letter-spacing: 3px; 
                font-size: 14px; 
            }
            #statusLog { 
                background: transparent; 
                border: none; 
                font-family: 'Courier'; 
                font-size: 11px; 
                color: #A0A0A0; 
            }
            
            #mainHeader { 
                color: white; 
                font-family: 'Avenir'; 
                font-size: 42px; 
                font-weight: 900; 
                letter-spacing: 12px; 
            }
            
            #scorePanel { 
                background-color: rgba(255, 255, 255, 0.05); 
                border: 1px solid rgba(255, 255, 255, 0.1); 
                border-radius: 15px; 
            }
            #scoreText { 
                color: #D4AF37; 
                font-family: 'Avenir'; 
                font-size: 95px; 
                font-weight: 900; 
            }
            #statusLabel { 
                color: white; 
                font-family: 'Avenir'; 
                font-size: 18px; 
                font-weight: 600; 
                letter-spacing: 4px; 
                text-transform: uppercase; 
                opacity: 0.8;
            }
            
            #metricCard { 
                background-color: rgba(255, 255, 255, 0.03); 
                border: 1px solid rgba(255, 255, 255, 0.1); 
                border-radius: 8px; 
                padding: 20px; 
            }
            #cardTitle { 
                color: rgba(255, 255, 255, 0.6); 
                font-family: 'Avenir'; 
                font-size: 11px; 
                font-weight: 800; 
                letter-spacing: 2px; 
            }
            #cardValue { 
                color: white; 
                font-family: 'Avenir'; 
                font-size: 24px; 
                font-weight: 900; 
            }
            
            #vizPlaceholder { 
                border: 1px dashed rgba(255, 255, 255, 0.2); 
                border-radius: 10px; 
                color: rgba(255, 255, 255, 0.3); 
                font-family: 'Avenir'; 
                font-size: 10px; 
            }
            
            QPushButton#modeButton {
                padding: 12px 25px; font-family: 'Avenir'; font-size: 12px; font-weight: 800; letter-spacing: 2px;
                background-color: transparent; color: white; border: 1px solid rgba(255, 255, 255, 0.2); border-radius: 5px;
            }
            QPushButton#modeButton:checked { 
                background-color: rgba(212, 175, 55, 0.2); 
                color: #D4AF37; 
                border: 1px solid #D4AF37; 
            }
            
            QPushButton { 
                padding: 18px 45px; 
                font-family: 'Avenir'; 
                font-size: 14px; 
                font-weight: 900; 
                letter-spacing: 3px; 
                border-radius: 5px; 
                border: 1px solid rgba(255, 255, 255, 0.2); 
            }
            QPushButton#actionButton { 
                background-color: rgba(255, 255, 255, 0.05); 
                color: white; 
            }
            QPushButton#actionButton:hover { 
                background-color: rgba(255, 255, 255, 0.1); 
            }
            QPushButton#masterButton { 
                background-color: #D4AF37; 
                color: #0A0E17; 
                border: none;
            }
            QPushButton#masterButton:hover {
                background-color: #E5C05B;
            }
            QPushButton:disabled { 
                border: 1px solid rgba(255, 255, 255, 0.05); 
                color: rgba(255, 255, 255, 0.2); 
                background-color: transparent; 
            }
        """)

    def update_log(self, text):
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.status_log.append(f"[{timestamp}] {text}")
        self.status_log.verticalScrollBar().setValue(self.status_log.verticalScrollBar().maximum())

    def select_file(self):
        if self.is_processing: return
        file_path, _ = QFileDialog.getOpenFileName(self, "Select Audio", "", "Audio Files (*.mp3 *.wav *.m4a *.flac)")
        if file_path: self.start_analysis(file_path)

    def start_analysis(self, file_path):
        self.is_processing = True
        self.update_log(f"Loading: {os.path.basename(file_path)}")
        self.load_btn.setEnabled(False)
        self.master_btn.setEnabled(False)
        
        self.thread = AnalysisThread(file_path)
        self.thread.status.connect(self.update_log)
        self.thread.finished.connect(self.on_analysis_finished)
        self.thread.error.connect(self.on_analysis_error)
        self.thread.start()

    def on_analysis_finished(self, report):
        self.is_processing = False
        self.load_btn.setEnabled(True)
        self.master_btn.setEnabled(True)
        self.current_analysis = report
        
        metrics = report["metrics"]
        self.score_label.setText(f"{report['cohesion_score']}%")
        self.current_status_label.setText(report["status"])
        
        self.lufs_card.value_label.setText(f"{metrics['integrated_lufs']} LUFS")
        self.slope_card.value_label.setText(f"{metrics['spectral_slope']}")
        self.stereo_card.value_label.setText(f"{metrics['correlation']}")
        self.update_log("Analysis Ready.")

    def run_mastering(self):
        if not self.current_analysis or self.is_processing: return
        self.is_processing = True
        self.master_btn.setEnabled(False); self.load_btn.setEnabled(False)
        
        app_dir = os.path.dirname(os.path.abspath(__file__))
        i = 1
        prefix = "CLEAR" if self.current_mode == "CLEAR" else "MASTER"
        while os.path.exists(os.path.join(app_dir, f"{prefix}{i}.wav")): i += 1
        output_path = os.path.join(app_dir, f"{prefix}{i}.wav")
        
        self.m_thread = MasteringThread(self.current_analysis["analysis_path"], self.current_analysis["metrics"], output_path, mode=self.current_mode)
        self.m_thread.status.connect(self.update_log)
        self.m_thread.finished.connect(self.on_mastering_finished)
        self.m_thread.error.connect(self.on_analysis_error)
        self.m_thread.start()

    def on_mastering_finished(self, output_path):
        self.is_processing = False
        self.load_btn.setEnabled(True); self.master_btn.setEnabled(True)
        self.update_log(f"SUCCESS: Saved to {os.path.basename(output_path)}")
        if self.current_analysis and self.current_analysis.get("is_temp"):
            try: os.remove(self.current_analysis["analysis_path"]); self.current_analysis["is_temp"] = False
            except: pass

    def on_analysis_error(self, message):
        self.is_processing = False
        self.load_btn.setEnabled(True); self.master_btn.setEnabled(True)
        self.update_log(f"CRITICAL ERROR: {message}")
        self.current_status_label.setText("ERROR")

if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    app = QApplication(sys.argv)
    window = MasterEvaluatorApp(); window.show()
    sys.exit(app.exec())
