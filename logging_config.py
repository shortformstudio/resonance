import logging
import os

def get_logger():
    logger = logging.getLogger("AudioMasterEvaluator")
    if not logger.handlers:
        logger.setLevel(logging.INFO)
        # Create console handler
        ch = logging.StreamHandler()
        ch.setLevel(logging.INFO)
        # Create formatter
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        ch.setFormatter(formatter)
        logger.addHandler(ch)
    return logger
