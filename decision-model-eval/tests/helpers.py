import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "decision_eval"))
sys.path.insert(0, HERE)
FAKE_LLM = os.path.join(HERE, "fake_llm.py")
