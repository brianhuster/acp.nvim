# X11 requires the application to run to keep the clipboard data available
import sys
from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import QMimeData, QUrl
from PyQt5.QtGui import QImage

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
    # mime.setImageData(image)
    mime.setImageData(image.convertToFormat(QImage.Format_RGB32))

elif mode == "uri":
    urls = [QUrl.fromLocalFile(p) for p in paths]
    mime.setUrls(urls)

elif mode == "text":
    mime.setText("\n".join(paths))

else:
    print("Invalid mode. Use: image | uri | text")
    sys.exit(1)

clipboard = app.clipboard()
clipboard.setMimeData(mime)

app.exec_()
