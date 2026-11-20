import os
import sys
import time
import locale
import socket
import subprocess
import threading
import tkinter as tk
from tkinter import messagebox
import av
import pyvirtualcam

HOST = '127.0.0.1'
PORT = 8888
WIDTH = 1920
HEIGHT = 1080
FPS = 60

TEXTS = {
    "PL": {
        "title": "iPhone Webcam PC",
        "torch_off": "Latarka: WYŁĄCZONA",
        "torch_on": "Latarka: WŁĄCZONA",
        "focus_af": "Focus: Automatyczny (AF)",
        "focus_mf": "Focus: Ręczny (MF)",
        "focus_lbl": "Ostrość ręczna (Blisko 0.0  ↔  1.0 Daleko):",
        "err_cam_title": "Błąd kamery wirtualnej",
        "err_cam_msg": "Nie udało się uruchomić OBS Virtual Camera:\n{}",
        "err_conn_title": "Brak połączenia z iPhonem",
        "err_conn_msg": (
            "Nie wykryto aplikacji iPhoneWebcam na porcie 8888.\n\n"
            "Upewnij się, że:\n"
            "1. iPhone jest podłączony kablem USB i odblokowany.\n"
            "2. Aplikacja iPhoneWebcam jest otwarta na ekranie telefonu."
        ),
    },
    "EN": {
        "title": "iPhone Webcam PC",
        "torch_off": "Flashlight: OFF",
        "torch_on": "Flashlight: ON",
        "focus_af": "Focus: Auto (AF)",
        "focus_mf": "Focus: Manual (MF)",
        "focus_lbl": "Manual Focus (Near 0.0  ↔  1.0 Far):",
        "err_cam_title": "Virtual Camera Error",
        "err_cam_msg": "Failed to start OBS Virtual Camera:\n{}",
        "err_conn_title": "iPhone Not Connected",
        "err_conn_msg": (
            "iPhoneWebcam app was not detected on port 8888.\n\n"
            "Please make sure that:\n"
            "1. Your iPhone is connected via USB cable and unlocked.\n"
            "2. The iPhoneWebcam app is open on your phone screen."
        ),
    }
}

def detect_lang() -> str:
    try:
        sys_lang = locale.getlocale()[0] or os.environ.get("LANG", "")
        if "pl" in sys_lang.lower() or "polish" in sys_lang.lower():
            return "PL"
    except Exception:
        pass
    return "EN"

current_lang = detect_lang()
sock = None
iproxy_proc = None
running = True

def get_resource_path(filename: str) -> str:
    base_dir = getattr(sys, '_MEIPASS', os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, filename)

def start_iproxy():
    global iproxy_proc
    iproxy_path = get_resource_path("iproxy.exe")
    if os.path.exists(iproxy_path):
        creation_flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
        iproxy_proc = subprocess.Popen(
            [iproxy_path, str(PORT), str(PORT)],
            cwd=os.path.dirname(iproxy_path),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creation_flags
        )
        time.sleep(1.2)

def stop_all():
    global running, sock, iproxy_proc
    running = False
    if sock:
        try:
            sock.close()
        except Exception:
            pass
    if iproxy_proc:
        try:
            iproxy_proc.terminate()
        except Exception:
            pass

def send_cmd(cmd: str):
    if sock:
        try:
            sock.sendall((cmd + "\n").encode("utf-8"))
        except Exception:
            pass

def video_loop(root: tk.Tk):
    global running
    try:
        codec = av.CodecContext.create('h264', 'r')
        codec.thread_type = 'SLICE'

        with pyvirtualcam.Camera(width=WIDTH, height=HEIGHT, fps=FPS, fmt=pyvirtualcam.PixelFormat.I420) as cam:
            while running:
                try:
                    data = sock.recv(131072)
                    if not data:
                        break
                except Exception:
                    break

                latest_frame = None
                for packet in codec.parse(data):
                    try:
                        for frame in codec.decode(packet):
                            latest_frame = frame
                    except av.error.InvalidDataError:
                        continue

                if latest_frame is not None:
                    img = latest_frame.to_ndarray(width=WIDTH, height=HEIGHT, format='yuv420p')
                    cam.send(img)
    except Exception as e:
        if running:
            t = TEXTS[current_lang]
            root.after(0, lambda: messagebox.showerror(t["err_cam_title"], t["err_cam_msg"].format(e)))
            root.after(0, root.destroy)

def build_ui():
    global current_lang
    root = tk.Tk()
    root.title(TEXTS[current_lang]["title"])
    root.geometry("330x255")
    root.resizable(False, False)
    root.attributes("-topmost", True)

    ico_path = get_resource_path("camera.ico")
    if os.path.exists(ico_path):
        try:
            root.iconbitmap(ico_path)
        except Exception:
            pass

    torch_on = tk.BooleanVar(value=False)
    manual_focus = tk.BooleanVar(value=False)

    def refresh_texts():
        t = TEXTS[current_lang]
        root.title(t["title"])
        btn_lang.config(text="Język: PL 🇵🇱" if current_lang == "PL" else "Language: EN 🇬🇧")
        btn_torch.config(text=t["torch_on"] if torch_on.get() else t["torch_off"])
        btn_focus.config(text=t["focus_mf"] if manual_focus.get() else t["focus_af"])
        lbl.config(text=t["focus_lbl"])

    def toggle_lang():
        global current_lang
        current_lang = "EN" if current_lang == "PL" else "PL"
        refresh_texts()

    def toggle_torch():
        new_state = not torch_on.get()
        torch_on.set(new_state)
        send_cmd("TORCH:1" if new_state else "TORCH:0")
        btn_torch.config(bg="#facc15" if new_state else "#e5e7eb")
        refresh_texts()

    def toggle_focus():
        new_state = not manual_focus.get()
        manual_focus.set(new_state)
        send_cmd("MF" if new_state else "AF")
        btn_focus.config(bg="#60a5fa" if new_state else "#e5e7eb")
        slider.config(state="normal" if new_state else "disabled")
        refresh_texts()

    def on_slider(val):
        if manual_focus.get():
            send_cmd(f"FOCUS:{float(val):.2f}")

    def on_close():
        stop_all()
        root.destroy()

    top_bar = tk.Frame(root)
    top_bar.pack(fill="x", padx=16, pady=(10, 4))
    btn_lang = tk.Button(top_bar, text="", font=("Segoe UI", 8, "bold"), bg="#f3f4f6", relief="groove", command=toggle_lang)
    btn_lang.pack(side="right")

    btn_torch = tk.Button(root, text="", font=("Segoe UI", 10, "bold"), bg="#e5e7eb", height=2, command=toggle_torch)
    btn_torch.pack(fill="x", padx=16, pady=(4, 8))

    btn_focus = tk.Button(root, text="", font=("Segoe UI", 10, "bold"), bg="#e5e7eb", height=2, command=toggle_focus)
    btn_focus.pack(fill="x", padx=16, pady=4)

    lbl = tk.Label(root, text="", font=("Segoe UI", 9))
    lbl.pack(pady=(8, 0))

    slider = tk.Scale(root, from_=0.0, to=1.0, resolution=0.01, orient="horizontal", state="disabled", command=on_slider)
    slider.set(0.5)
    slider.pack(fill="x", padx=16)

    refresh_texts()

    t_thread = threading.Thread(target=video_loop, args=(root,), daemon=True)
    t_thread.start()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()
    stop_all()

def main():
    global sock
    start_iproxy()

    connected = False
    for _ in range(3):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(2.0)
            s.connect((HOST, PORT))
            s.settimeout(None)
            sock = s
            connected = True
            break
        except Exception:
            time.sleep(0.8)

    if not connected:
        t = TEXTS[current_lang]
        temp_root = tk.Tk()
        temp_root.withdraw()
        messagebox.showerror(t["err_conn_title"], t["err_conn_msg"])
        temp_root.destroy()
        stop_all()
        return

    build_ui()

if __name__ == '__main__':
    main()
