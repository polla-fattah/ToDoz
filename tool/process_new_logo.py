"""
Extracts and generates all application, installer, and website branding assets from the new logo.
"""
import os
import cv2
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_LOGO = os.path.join(r"C:\Users\polla\.gemini\antigravity-ide\brain\1db896bd-dcac-49a7-9474-f1517174cf76\.user_uploaded\media_1792455552231.jpg")

def extract_squircle_mark(src_path):
    img = Image.open(src_path).convert('RGB')
    arr = np.array(img)
    
    # 1. Detect background (white)
    # Background is nearly white (R>215, G>220, B>235) in the top 630 rows
    top_region = arr[:630, :]
    is_bg = (top_region[:, :, 0] > 215) & (top_region[:, :, 1] > 220) & (top_region[:, :, 2] > 235)
    
    mask = np.zeros(top_region.shape[:2], dtype=np.uint8)
    mask[~is_bg] = 255
    
    # Find outer contour of the squircle
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    largest_cnt = max(contours, key=cv2.contourArea)
    
    # Render antialiased alpha mask
    alpha = np.zeros(top_region.shape[:2], dtype=np.uint8)
    cv2.drawContours(alpha, [largest_cnt], -1, 255, thickness=cv2.FILLED)
    
    # Erode slightly (1px) to avoid white fringe, then Gaussian blur edge
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    alpha = cv2.erode(alpha, kernel, iterations=1)
    alpha = cv2.GaussianBlur(alpha, (3, 3), 0.7)
    
    # Combine with original RGB
    rgba = np.dstack((top_region, alpha))
    
    # Crop tightly to the mark
    ys, xs = np.where(alpha > 10)
    tight_crop = rgba[ys.min():ys.max()+1, xs.min():xs.max()+1]
    
    mark_img = Image.fromarray(tight_crop)
    return mark_img

def on_canvas(img, size=1024, fill_ratio=0.88):
    """Centers the mark on a transparent square canvas of the given size."""
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    target_dim = int(size * fill_ratio)
    
    w, h = img.size
    scale = min(target_dim / w, target_dim / h)
    new_w, new_h = int(w * scale), int(h * scale)
    
    resized = img.resize((new_w, new_h), Image.LANCZOS)
    offset_x = (size - new_w) // 2
    offset_y = (size - new_h) // 2
    
    canvas.paste(resized, (offset_x, offset_y), resized)
    return canvas

def make_monochrome(img):
    """Creates a white-only monochrome icon using the alpha channel."""
    arr = np.array(img).copy()
    arr[..., 0] = 255
    arr[..., 1] = 255
    arr[..., 2] = 255
    return Image.fromarray(arr)

def main():
    print(f"Loading logo from: {SRC_LOGO}")
    mark = extract_squircle_mark(SRC_LOGO)
    print(f"Extracted squircle mark: {mark.size}")
    
    # 1. Save core branding assets
    branding_dir = os.path.join(ROOT, 'assets', 'branding')
    os.makedirs(branding_dir, exist_ok=True)
    
    icon_1024 = on_canvas(mark, 1024, 0.90)
    icon_1024.save(os.path.join(branding_dir, 'todoz_mark.png'))
    icon_1024.save(os.path.join(branding_dir, 'notedo_mark.png'))
    print("Saved assets/branding/todoz_mark.png")
    
    # 2. Windows Icon (.ico)
    windows_res_dir = os.path.join(ROOT, 'windows', 'runner', 'resources')
    os.makedirs(windows_res_dir, exist_ok=True)
    ico_canvas = on_canvas(mark, 256, 0.92)
    ico_path = os.path.join(windows_res_dir, 'app_icon.ico')
    ico_canvas.save(ico_path, format='ICO', sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)])
    print(f"Saved {ico_path}")
    
    # 3. Android Mipmaps
    android_res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for name, factor in densities.items():
        d = os.path.join(android_res, f'mipmap-{name}')
        os.makedirs(d, exist_ok=True)
        # Adaptive foreground: safe zone is middle 66 of 108dp
        fg = on_canvas(mark, round(108 * factor), 0.65)
        fg.save(os.path.join(d, 'ic_launcher_foreground.png'))
        make_monochrome(fg).save(os.path.join(d, 'ic_launcher_monochrome.png'))
        # Legacy launcher icon (48dp base)
        legacy = on_canvas(mark, round(48 * factor), 0.90)
        legacy.save(os.path.join(d, 'ic_launcher.png'))
    print("Saved Android mipmap launcher icons")
    
    # 4. Website Favicons and Images
    landing_img_dir = os.path.join(ROOT, 'landing', 'images')
    os.makedirs(landing_img_dir, exist_ok=True)
    
    web_icon_512 = on_canvas(mark, 512, 0.92)
    web_icon_512.save(os.path.join(landing_img_dir, 'icon.png'))
    
    web_icon_192 = on_canvas(mark, 192, 0.92)
    web_icon_192.save(os.path.join(landing_img_dir, 'icon-192.png'))
    
    apple_icon = on_canvas(mark, 180, 0.92)
    apple_icon.save(os.path.join(landing_img_dir, 'apple-touch-icon.png'))
    
    web_ico = on_canvas(mark, 64, 0.92)
    web_ico.save(os.path.join(ROOT, 'landing', 'favicon.ico'), format='ICO', sizes=[(64, 64), (32, 32), (16, 16)])
    print("Saved landing web icons and favicon.ico")

if __name__ == '__main__':
    main()
