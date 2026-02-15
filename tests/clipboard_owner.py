# X11 requires the application to run to keep the clipboard data available
import sys
import os

from PyQt6.QtWidgets import QApplication
from PyQt6.QtCore import QMimeData, QUrl
from PyQt6.QtGui import QImage

app = QApplication(sys.argv)

if len(sys.argv) < 3:
    print("Usage:")
    print("  image mode: clipboard_owner.py image <file_path>")
    print("  uri mode:   clipboard_owner.py uri <file1> <file2> ...")
    print("  text mode:  clipboard_owner.py text <file1> <file2> ...")
    sys.exit(1)

mode = sys.argv[1]
paths = sys.argv[2:]

mime = QMimeData()

if mode == "image":
    if len(paths) != 1:
        print("Image mode requires exactly one file path.")
        sys.exit(1)

    image = QImage(paths[0])
    if image.isNull():
        print(f"Failed to load image from {paths[0]}")
        sys.exit(1)

    # Ensure consistent format for clipboard
    image = image.convertToFormat(QImage.Format.Format_RGB32)
    mime.setImageData(image)
    app.clipboard().setMimeData(mime)

elif mode == "uri":
    abs_paths = [os.path.abspath(p) for p in paths]
    if sys.platform == "darwin":
        from AppKit import NSPasteboard, NSURL
        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        file_urls = [NSURL.fileURLWithPath_(p) for p in abs_paths]
        pb.writeObjects_(file_urls)
    else:
        urls = [QUrl.fromLocalFile(p) for p in abs_paths]
        mime.setUrls(urls)
        app.clipboard().setMimeData(mime)

elif mode == "text":
    mime.setText("\n".join(paths))
    app.clipboard().setMimeData(mime)

else:
    print("Invalid mode. Use: image | uri | text")
    sys.exit(1)

app.exec()
